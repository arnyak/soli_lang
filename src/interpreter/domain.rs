//! Domain modelling support: value objects, invariants and domain errors.
//!
//! Shared by both engines, so the tree-walker and the VM build, compare,
//! freeze and serialize value objects the same way.

use std::cell::RefCell;
use std::rc::Rc;

use super::value::{Class, Instance, Value};

thread_local! {
    /// The built-in `DomainError` and `InvariantViolation` classes, so Rust
    /// code can raise them. Set when the builtins are registered.
    static ERROR_CLASSES: RefCell<Option<(Rc<Class>, Rc<Class>)>> = const { RefCell::new(None) };
}

/// Remember the built-in domain error classes (see [`ERROR_CLASSES`]).
pub fn remember_error_classes(domain_error: Rc<Class>, invariant_violation: Rc<Class>) {
    ERROR_CLASSES.with(|c| *c.borrow_mut() = Some((domain_error, invariant_violation)));
}

/// A new `InvariantViolation` carrying `message` and `details`, ready to throw.
/// Falls back to the message alone (a string) before the builtins exist.
pub fn invariant_violation(message: &str, details: Value) -> Value {
    ERROR_CLASSES.with(|c| match c.borrow().as_ref() {
        Some((_, class)) => {
            let mut instance = Instance::new(class.clone());
            instance.set("message", Value::String(message.to_string().into()));
            instance.set("details", details);
            Value::Instance(Rc::new(RefCell::new(instance)))
        }
        None => Value::String(message.to_string().into()),
    })
}
