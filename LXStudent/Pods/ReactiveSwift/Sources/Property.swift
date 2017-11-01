#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import Darwin.POSIX.pthread
#else
import Glibc
#endif
import enum Result.NoError

/// Represents a property that allows observation of its changes.
///
/// Only classes can conform to this protocol, because having a signal
/// for changes over time implies the origin must have a unique identity.
public protocol PropertyProtocol: class, BindingSource {
	associatedtype Value

	/// The current value of the property.
	var value: Value { get }

	/// The values producer of the property.
	///
	/// It produces a signal that sends the property's current value,
	/// followed by all changes over time. It completes when the property
	/// has deinitialized, or has no further change.
	///
	/// - note: If `self` is a composed property, the producer would be
	///         bound to the lifetime of its sources.
	var producer: SignalProducer<Value, NoError> { get }

	/// A signal that will send the property's changes over time. It
	/// completes when the property has deinitialized, or has no further
	/// change.
	///
	/// - note: If `self` is a composed property, the signal would be
	///         bound to the lifetime of its sources.
	var signal: Signal<Value, NoError> { get }
}

/// Represents an observable property that can be mutated directly.
public protocol MutablePropertyProtocol: PropertyProtocol, BindingTargetProvider {
	/// The current value of the property.
	var value: Value { get set }

	/// The lifetime of the property.
	var lifetime: Lifetime { get }
}

/// Default implementation of `BindingTargetProvider` for mutable properties.
extension MutablePropertyProtocol {
	public var bindingTarget: BindingTarget<Value> {
		return BindingTarget(lifetime: lifetime) { [weak self] in self?.value = $0 }
	}
}

/// Represents a mutable property that can be safety composed by exposing its
/// synchronization mechanic through the defined closure-based interface.
public protocol ComposableMutablePropertyProtocol: MutablePropertyProtocol {
	/// Atomically performs an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that accepts current property value.
	///
	/// - returns: the result of the action.
	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result

	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that accepts old property value and returns a new
	///             property value.
	///
	/// - returns: The result of the action.
	func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result
}

// Property operators.
//
// A composed property is a transformed view of its sources, and does not
// own its lifetime. Its producer and signal are bound to the lifetime of
// its sources.

extension PropertyProtocol {
	/// Lifts a unary SignalProducer operator to operate upon PropertyProtocol instead.
	fileprivate func lift<U>(_ transform: @escaping (SignalProducer<Value, NoError>) -> SignalProducer<U, NoError>) -> Property<U> {
		return Property(unsafeProducer: transform(producer))
	}

	/// Lifts a binary SignalProducer operator to operate upon PropertyProtocol instead.
	fileprivate func lift<P: PropertyProtocol, U>(_ transform: @escaping (SignalProducer<Value, NoError>) -> (SignalProducer<P.Value, NoError>) -> SignalProducer<U, NoError>) -> (P) -> Property<U> {
		return { other in
			return Property(unsafeProducer: transform(self.producer)(other.producer))
		}
	}
}

extension PropertyProtocol where Error == NoError {
	/// Maps the current value and all subsequent values to a new property.
	///
	/// - parameters:
	///   - transform: A closure that will map the current `value` of this
	///                `Property` to a new value.
	///
	/// - returns: A property that holds a mapped value from `self`.
	public func map<U>(_ transform: @escaping (Value) -> U) -> Property<U> {
		return lift { $0.map(transform) }
	}

#if swift(>=3.2)
	/// Maps the current value and all subsequent values to a new property
	/// by applying a key path.
	///
	/// - parameters:
	///   - keyPath: A key path relative to the property's `Value` type.
	///
	/// - returns: A property that holds a mapped value from `self`.
	public func map<U>(_ keyPath: KeyPath<Value, U>) -> Property<U> {
		return lift { $0.map(keyPath) }
	}
#endif

	/// Combines the current value and the subsequent values of two `Property`s in
	/// the manner described by `Signal.combineLatest(with:)`.
	///
	/// - parameters:
	///   - other: A property to combine `self`'s value with.
	///
	/// - returns: A property that holds a tuple containing values of `self` and
	///            the given property.
	public func combineLatest<P: PropertyProtocol>(with other: P) -> Property<(Value, P.Value)> where P.Error == NoError {
		return Property.combineLatest(self, other)
	}

	/// Zips the current value and the subsequent values of two `Property`s in
	/// the manner described by `Signal.zipWith`.
	///
	/// - parameters:
	///   - other: A property to zip `self`'s value with.
	///
	/// - returns: A property that holds a tuple containing values of `self` and
	///            the given property.
	public func zip<P: PropertyProtocol>(with other: P) -> Property<(Value, P.Value)> where P.Error == NoError {
		return Property.zip(self, other)
	}

	/// Forward events from `self` with history: values of the returned property
	/// are a tuple whose first member is the previous value and whose second
	/// member is the current value. `initial` is supplied as the first member
	/// when `self` sends its first value.
	///
	/// - parameters:
	///   - initial: A value that will be combined with the first value sent by
	///              `self`.
	///
	/// - returns: A property that holds tuples that contain previous and
	///            current values of `self`.
	public func combinePrevious(_ initial: Value) -> Property<(Value, Value)> {
		return lift { $0.combinePrevious(initial) }
	}

	/// Forward only values from `self` that are not considered equivalent to its
	/// consecutive predecessor.
	///
	/// - note: The first value is always forwarded.
	///
	/// - parameters:
	///   - isEquivalent: A closure to determine whether two values are equivalent.
	///
	/// - returns: A property which conditionally forwards values from `self`.
	public func skipRepeats(_ isEquivalent: @escaping (Value, Value) -> Bool) -> Property<Value> {
		return lift { $0.skipRepeats(isEquivalent) }
	}
}

extension PropertyProtocol where Value: Equatable {
	/// Forward only values from `self` that are not equal to its consecutive predecessor.
	///
	/// - note: The first value is always forwarded.
	///
	/// - returns: A property which conditionally forwards values from `self`.
	public func skipRepeats() -> Property<Value> {
		return lift { $0.skipRepeats() }
	}
}

extension PropertyProtocol where Value: PropertyProtocol {
	/// Flattens the inner property held by `self` (into a single property of
	/// values), according to the semantics of the given strategy.
	///
	/// - parameters:
	///   - strategy: The preferred flatten strategy.
	///
	/// - returns: A property that sends the values of its inner properties.
	public func flatten(_ strategy: FlattenStrategy) -> Property<Value.Value> {
		return lift { $0.flatMap(strategy) { $0.producer } }
	}
}

extension PropertyProtocol {
	/// Maps each property from `self` to a new property, then flattens the
	/// resulting properties (into a single property), according to the
	/// semantics of the given strategy.
	///
	/// - parameters:
	///   - strategy: The preferred flatten strategy.
	///   - transform: The transform to be applied on `self` before flattening.
	///
	/// - returns: A property that sends the values of its inner properties.
	public func flatMap<P: PropertyProtocol>(_ strategy: FlattenStrategy, _ transform: @escaping (Value) -> P) -> Property<P.Value> {
		return lift { $0.flatMap(strategy) { transform($0).producer } }
	}

	/// Forward only those values from `self` that have unique identities across
	/// the set of all values that have been held.
	///
	/// - note: This causes the identities to be retained to check for 
	///         uniqueness.
	///
	/// - parameters:
	///   - transform: A closure that accepts a value and returns identity
	///                value.
	///
	/// - returns: A property that sends unique values during its lifetime.
	public func uniqueValues<Identity: Hashable>(_ transform: @escaping (Value) -> Identity) -> Property<Value> {
		return lift { $0.uniqueValues(transform) }
	}
}

extension PropertyProtocol where Value: Hashable {
	/// Forwards only those values from `self` that are unique across the set of
	/// all values that have been seen.
	///
	/// - note: This causes the identities to be retained to check for uniqueness.
	///         Providing a function that returns a unique value for each sent
	///         value can help you reduce the memory footprint.
	///
	/// - returns: A property that sends unique values during its lifetime.
	public func uniqueValues() -> Property<Value> {
		return lift { $0.uniqueValues() }
	}
}

extension PropertyProtocol {
	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol>(_ a: A, _ b: B) -> Property<(A.Value, B.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error {
		return a.lift { SignalProducer.combineLatest($0, b) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol>(_ a: A, _ b: B, _ c: C) -> Property<(Value, B.Value, C.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D) -> Property<(Value, B.Value, C.Value, D.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E) -> Property<(Value, B.Value, C.Value, D.Value, E.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e, f) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e, f, g) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e, f, g, h) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol, I: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e, f, g, h, i) }
	}

	/// Combines the values of all the given properties, in the manner described
	/// by `combineLatest(with:)`.
	public static func combineLatest<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol, I: PropertyProtocol, J: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value, J.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error, A.Error == J.Error {
		return a.lift { SignalProducer.combineLatest($0, b, c, d, e, f, g, h, i, j) }
	}

	/// Combines the values of all the given producers, in the manner described by
	/// `combineLatest(with:)`. Returns nil if the sequence is empty.
	public static func combineLatest<S: Sequence>(_ properties: S) -> Property<[S.Iterator.Element.Value]>? where S.Iterator.Element: PropertyProtocol {
		let producers = properties.map { $0.producer }
		guard !producers.isEmpty else {
			return nil
		}

		return Property(unsafeProducer: SignalProducer.combineLatest(producers))
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol>(_ a: A, _ b: B) -> Property<(Value, B.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error {
		return a.lift { SignalProducer.zip($0, b) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol>(_ a: A, _ b: B, _ c: C) -> Property<(Value, B.Value, C.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error {
		return a.lift { SignalProducer.zip($0, b, c) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D) -> Property<(Value, B.Value, C.Value, D.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error {
		return a.lift { SignalProducer.zip($0, b, c, d) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E) -> Property<(Value, B.Value, C.Value, D.Value, E.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e, f) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e, f, g) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e, f, g, h) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol, I: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e, f, g, h, i) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`.
	public static func zip<A: PropertyProtocol, B: PropertyProtocol, C: PropertyProtocol, D: PropertyProtocol, E: PropertyProtocol, F: PropertyProtocol, G: PropertyProtocol, H: PropertyProtocol, I: PropertyProtocol, J: PropertyProtocol>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J) -> Property<(Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value, J.Value)> where A.Value == Value, A.Error == NoError, A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error, A.Error == J.Error {
		return a.lift { SignalProducer.zip($0, b, c, d, e, f, g, h, i, j) }
	}

	/// Zips the values of all the given properties, in the manner described by
	/// `zip(with:)`. Returns nil if the sequence is empty.
	public static func zip<S: Sequence>(_ properties: S) -> Property<[S.Iterator.Element.Value]>? where S.Iterator.Element: PropertyProtocol {
		let producers = properties.map { $0.producer }
		guard !producers.isEmpty else {
			return nil
		}

		return Property(unsafeProducer: SignalProducer.zip(producers))
	}
}

extension PropertyProtocol where Value == Bool {
	/// Create a property that computes a logical NOT in the latest values of `self`.
	///
	/// - returns: A property that contains the logial NOT results.
	public func negate() -> Property<Value> {
		return self.lift { $0.negate() }
	}

	/// Create a property that computes a logical AND between the latest values of `self`
	/// and `property`.
	///
	/// - parameters:
	///   - property: Property to be combined with `self`.
	///
	/// - returns: A property that contains the logial AND results.
	public func and<P: PropertyProtocol>(_ property: P) -> Property<Value> where P.Value == Value {
		return self.lift(SignalProducer.and)(property)
	}

	/// Create a property that computes a logical OR between the latest values of `self`
	/// and `property`.
	///
	/// - parameters:
	///   - property: Property to be combined with `self`.
	///
	/// - returns: A property that contains the logial OR results.
	public func or<P: PropertyProtocol>(_ property: P) -> Property<Value> where P.Value == Value {
		return self.lift(SignalProducer.or)(property)
	}
}

/// A read-only property that can be observed for its changes over time. There
/// are three categories of read-only properties:
///
/// # Constant property
/// Created by `Property(value:)`, the producer and signal of a constant
/// property would complete immediately when it is initialized.
///
/// # Existential property
/// Created by `Property(capturing:)`, it wraps any arbitrary `PropertyProtocol`
/// types, and passes through the behavior. Note that it would retain the
/// wrapped property.
///
/// Existential property would be deprecated when generalized existential
/// eventually lands in Swift.
///
/// # Composed property
/// A composed property presents a composed view of its sources, which can be
/// one or more properties, a producer, or a signal. It can be created using
/// property composition operators, `Property(_:)` or `Property(initial:then:)`.
///
/// It does not own its lifetime, and its producer and signal are bound to the
/// lifetime of its sources. It also does not have an influence on its sources,
/// so retaining a composed property would not prevent its sources from
/// deinitializing.
///
/// Note that composed properties do not retain any of its sources.
public final class Property<Value>: PropertyProtocol {
	private let _value: () -> Value

	/// The current value of the property.
	public var value: Value {
		return _value()
	}

	/// A producer for Signals that will send the property's current
	/// value, followed by all changes over time, then complete when the
	/// property has deinitialized or has no further changes.
	///
	/// - note: If `self` is a composed property, the producer would be
	///         bound to the lifetime of its sources.
	public let producer: SignalProducer<Value, NoError>

	/// A signal that will send the property's changes over time, then
	/// complete when the property has deinitialized or has no further changes.
	///
	/// - note: If `self` is a composed property, the signal would be
	///         bound to the lifetime of its sources.
	public let signal: Signal<Value, NoError>

	/// Initializes a constant property.
	///
	/// - parameters:
	///   - property: A value of the constant property.
	public init(value: Value) {
		_value = { value }
		producer = SignalProducer(value: value)
		signal = Signal<Value, NoError>.empty
	}

	/// Initializes an existential property which wraps the given property.
	///
	/// - note: The resulting property retains the given property.
	///
	/// - parameters:
	///   - property: A property to be wrapped.
	public init<P: PropertyProtocol>(capturing property: P) where P.Value == Value {
		_value = { property.value }
		producer = property.producer
		signal = property.signal
	}

	/// Initializes a composed property which reflects the given property.
	///
	/// - note: The resulting property does not retain the given property.
	///
	/// - parameters:
	///   - property: A property to be wrapped.
	public convenience init<P: PropertyProtocol>(_ property: P) where P.Value == Value {
		self.init(unsafeProducer: property.producer)
	}

	/// Initializes a composed property that first takes on `initial`, then each
	/// value sent on a signal created by `producer`.
	///
	/// - parameters:
	///   - initial: Starting value for the property.
	///   - values: A producer that will start immediately and send values to
	///             the property.
	public convenience init(initial: Value, then values: SignalProducer<Value, NoError>) {
		self.init(unsafeProducer: SignalProducer { observer, lifetime in
			observer.send(value: initial)
			let disposable = values.start(Signal.Observer(mappingInterruptedToCompleted: observer))
			lifetime.observeEnded(disposable.dispose)
		})
	}

	/// Initialize a composed property that first takes on `initial`, then each
	/// value sent on `signal`.
	///
	/// - parameters:
	///   - initialValue: Starting value for the property.
	///   - values: A signal that will send values to the property.
	public convenience init(initial: Value, then values: Signal<Value, NoError>) {
		self.init(initial: initial, then: SignalProducer(values))
	}

	/// Initialize a composed property from a producer that promises to send
	/// at least one value synchronously in its start handler before sending any
	/// subsequent event.
	///
	/// - important: The producer and the signal of the created property would
	///              complete only when the `unsafeProducer` completes.
	///
	/// - warning: If the producer fails its promise, a fatal error would be
	///            raised.
	///
	/// - warning: `unsafeProducer` should not emit any `interrupted` event unless it is
	///            a result of being interrupted by the downstream.
	///
	/// - parameters:
	///   - unsafeProducer: The composed producer for creating the property.
	fileprivate init(
		unsafeProducer: SignalProducer<Value, NoError>,
	    transform: ((Signal<Value, NoError>.Observer) -> Signal<Value, NoError>.Observer)? = nil
	) {
		// The ownership graph:
		//
		// ------------     weak  -----------    strong ------------------
		// | Upstream | ~~~~~~~~> |   Box   | <======== | SignalProducer | <=== strong
		// ------------           -----------       //  ------------------    \\
		//  \\                                     //                          \\
		//   \\   ------------ weak  ----------- <==                          ------------
		//    ==> | Observer | ~~~~> |  Relay  | <=========================== | Property |
		// strong ------------       -----------                       strong ------------

		let box = PropertyBox<Value?>(nil)
		var relay: Signal<Value, NoError>!

		unsafeProducer.startWithSignal { upstream, interruptHandle in
			// A composed property tracks its active consumers through its relay signal, and
			// interrupts `unsafeProducer` if the relay signal terminates.
			let (signal, _observer) = Signal<Value, NoError>.pipe(disposable: interruptHandle)
			let observer = transform?(_observer) ?? _observer
			relay = signal

			// `observer` receives `interrupted` only as a result of the termination of
			// `signal`, and would not be delivered anyway. So transforming
			// `interrupted` to `completed` is unnecessary here.
			upstream.observe { [weak box] event in
				guard let box = box else {
					// Just forward the event, since no one owns the box or IOW no demand
					// for a cached latest value.
					return observer.action(event)
				}

				box.begin { storage in
					storage.modify { value in
						if let newValue = event.value {
							value = newValue
						}
					}
					observer.action(event)
				}
			}
		}

		// Verify that an initial is sent. This is friendlier than deadlocking
		// in the event that one isn't.
		guard box.value != nil else {
			fatalError("The producer promised to send at least one value. Received none.")
		}

		_value = { box.value! }
		signal = relay

		producer = SignalProducer { [box, signal = relay!] observer, lifetime in
			box.withValue { value in
				observer.send(value: value!)
				lifetime += signal.observe(Signal.Observer(mappingInterruptedToCompleted: observer))
			}
		}
	}
}

extension Property where Value: OptionalProtocol {
	/// Initializes a composed property that first takes on `initial`, then each
	/// value sent on a signal created by `producer`.
	///
	/// - parameters:
	///   - initial: Starting value for the property.
	///   - values: A producer that will start immediately and send values to
	///             the property.
	public convenience init(initial: Value, then values: SignalProducer<Value.Wrapped, NoError>) {
		self.init(initial: initial, then: values.map(Value.init(reconstructing:)))
	}

	/// Initialize a composed property that first takes on `initial`, then each
	/// value sent on `signal`.
	///
	/// - parameters:
	///   - initialValue: Starting value for the property.
	///   - values: A signal that will send values to the property.
	public convenience init(initial: Value, then values: Signal<Value.Wrapped, NoError>) {
		self.init(initial: initial, then: SignalProducer(values))
	}
}

/// A mutable property of type `Value` that allows observation of its changes.
///
/// Instances of this class are thread-safe.
public final class MutableProperty<Value>: ComposableMutablePropertyProtocol {
	private let token: Lifetime.Token
	private let observer: Signal<Value, NoError>.Observer
	private let box: PropertyBox<Value>

	/// The current value of the property.
	///
	/// Setting this to a new value will notify all observers of `signal`, or
	/// signals created using `producer`.
	public var value: Value {
		get { return box.value }
		set { modify { $0 = newValue } }
	}

	/// The lifetime of the property.
	public let lifetime: Lifetime

	/// A signal that will send the property's changes over time,
	/// then complete when the property has deinitialized.
	public let signal: Signal<Value, NoError>

	/// A producer for Signals that will send the property's current value,
	/// followed by all changes over time, then complete when the property has
	/// deinitialized.
	public var producer: SignalProducer<Value, NoError> {
		return SignalProducer { [box, signal] observer, lifetime in
			box.withValue { value in
				observer.send(value: value)
				if let d = signal.observe(Signal.Observer(mappingInterruptedToCompleted: observer)) {
					lifetime.observeEnded(d.dispose)
				}
			}
		}
	}

	/// Initializes a mutable property that first takes on `initialValue`
	///
	/// - parameters:
	///   - initialValue: Starting value for the mutable property.
	public init(_ initialValue: Value) {
		(signal, observer) = Signal.pipe()
		token = Lifetime.Token()
		lifetime = Lifetime(token)

		/// Need a recursive lock around `value` to allow recursive access to
		/// `value`. Note that recursive sets will still deadlock because the
		/// underlying producer prevents sending recursive events.
		box = PropertyBox(initialValue)
	}

	/// Atomically replaces the contents of the variable.
	///
	/// - parameters:
	///   - newValue: New property value.
	///
	/// - returns: The previous property value.
	@discardableResult
	public func swap(_ newValue: Value) -> Value {
		return modify { value in
			defer { value = newValue }
			return value
		}
	}

	/// Atomically modifies the variable.
	///
	/// - parameters:
	///   - action: A closure that accepts an inout reference to the value.
	///
	/// - returns: The result of the action.
	@discardableResult
	public func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
		return try box.begin { storage in
			defer { observer.send(value: storage.value) }
			return try storage.modify(action)
		}
	}

	/// Atomically modifies the variable.
	///
	/// - warning: The reference should not be escaped.
	///
	/// - parameters:
	///   - action: A closure that accepts a reference to the property storage.
	///
	/// - returns: The result of the action.
	@discardableResult
	internal func begin<Result>(_ action: (PropertyStorage<Value>) throws -> Result) rethrows -> Result {
		return try box.begin(action)
	}

	/// Atomically performs an arbitrary action using the current value of the
	/// variable.
	///
	/// - parameters:
	///   - action: A closure that accepts current property value.
	///
	/// - returns: the result of the action.
	@discardableResult
	public func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		return try box.withValue { try action($0) }
	}

	deinit {
		observer.sendCompleted()
	}
}

internal struct PropertyStorage<Value> {
	private unowned let box: PropertyBox<Value>

	var value: Value {
		return box._value
	}

	func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
		guard !box.isModifying else { fatalError("Nested modifications violate exclusivity of access.") }
		box.isModifying = true
		defer { box.isModifying = false }
		return try action(&box._value)
	}

	fileprivate init(_ box: PropertyBox<Value>) {
		self.box = box
	}
}

/// A reference counted box which holds a recursive lock and a value storage.
///
/// The requirement of a `Value?` storage from composed properties prevents further
/// implementation sharing with `MutableProperty`.
private final class PropertyBox<Value> {

	private let lock: Lock.PthreadLock
	fileprivate var _value: Value
	fileprivate var isModifying = false

	internal var value: Value {
		lock.lock()
		defer { lock.unlock() }
		return _value
	}

	init(_ value: Value) {
		_value = value
		lock = Lock.PthreadLock(recursive: true)
	}

	func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try action(_value)
	}

	func begin<Result>(_ action: (PropertyStorage<Value>) throws -> Result) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }
		return try action(PropertyStorage(self))
	}
}