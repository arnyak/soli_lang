//! Lifecycle callbacks for models.

use std::cell::RefCell;

use super::core::MODEL_REGISTRY;

/// Lifecycle callbacks for a model.
#[derive(Debug, Clone, Default)]
pub struct ModelCallbacks {
    pub before_save: Vec<String>,
    pub after_save: Vec<String>,
    pub before_create: Vec<String>,
    pub after_create: Vec<String>,
    pub before_update: Vec<String>,
    pub after_update: Vec<String>,
    pub before_delete: Vec<String>,
    pub after_delete: Vec<String>,
}

impl ModelCallbacks {
    /// The list of one kind, `None` for a kind that does not exist.
    fn list_mut(&mut self, callback_type: &str) -> Option<&mut Vec<String>> {
        Some(match callback_type {
            "before_save" => &mut self.before_save,
            "after_save" => &mut self.after_save,
            "before_create" => &mut self.before_create,
            "after_create" => &mut self.after_create,
            "before_update" => &mut self.before_update,
            "after_update" => &mut self.after_update,
            "before_delete" => &mut self.before_delete,
            "after_delete" => &mut self.after_delete,
            _ => return None,
        })
    }
}

thread_local! {
    /// The callbacks of the model classes being declared on this thread —
    /// a stack, as a model class can declare another inside it. See
    /// [`Declaration`].
    static DECLARING: RefCell<Vec<(String, ModelCallbacks)>> = const { RefCell::new(Vec::new()) };
}

/// Register a callback for a model class.
///
/// In declaration order, and a name declared twice runs twice. While the
/// class's body runs, this adds to the list the body is building
/// ([`Declaration`]); otherwise to the class's registered list.
pub fn register_callback(class_name: &str, callback_type: &str, method_name: &str) {
    let declaring = DECLARING.with(|stack| {
        let mut stack = stack.borrow_mut();
        let Some((_, callbacks)) = stack.iter_mut().rev().find(|(name, _)| name == class_name)
        else {
            return false;
        };
        if let Some(list) = callbacks.list_mut(callback_type) {
            list.push(method_name.to_string());
        }
        true
    });
    if declaring {
        return;
    }
    MODEL_REGISTRY.write(|registry| {
        let metadata = registry.entry(class_name.to_string()).or_default();
        if let Some(list) = metadata.callbacks.list_mut(callback_type) {
            list.push(method_name.to_string());
        }
    })
}

/// The callbacks a model class's body declares, installed as a whole when
/// the body has run.
///
/// The body runs again on every hot reload, in every worker, and the
/// registry is process-wide. Appending to it straight away added each
/// callback again each time: after a day of edits, one `save` ran its
/// `before_save` thousands of times. Built aside and swapped in, the list is
/// the body's, whichever worker installs it last, and never seen half-built.
pub struct Declaration {
    class_name: String,
    installed: bool,
}

impl Declaration {
    /// Start collecting `class_name`'s callbacks, from `inherited` — the
    /// parent's list for a model that inherits from another, empty
    /// otherwise.
    pub fn begin(class_name: &str, inherited: ModelCallbacks) -> Self {
        DECLARING.with(|stack| stack.borrow_mut().push((class_name.to_string(), inherited)));
        Declaration {
            class_name: class_name.to_string(),
            installed: false,
        }
    }

    /// The body has run: its callbacks replace the class's.
    pub fn install(mut self) {
        if let Some(callbacks) = self.take() {
            MODEL_REGISTRY.write(|registry| {
                registry
                    .entry(self.class_name.clone())
                    .or_default()
                    .callbacks = callbacks;
            });
        }
        self.installed = true;
    }

    fn take(&self) -> Option<ModelCallbacks> {
        DECLARING.with(|stack| {
            let mut stack = stack.borrow_mut();
            let at = stack
                .iter()
                .rposition(|(name, _)| *name == self.class_name)?;
            Some(stack.remove(at).1)
        })
    }
}

impl Drop for Declaration {
    /// A body that failed half-way leaves the class's callbacks as they were.
    fn drop(&mut self) {
        if !self.installed {
            self.take();
        }
    }
}

/// The callbacks registered for `class_name`, empty when it has none.
pub fn registered(class_name: &str) -> ModelCallbacks {
    MODEL_REGISTRY.read(|registry| {
        registry
            .get(class_name)
            .map(|meta| meta.callbacks.clone())
            .unwrap_or_default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A class body run again — a hot reload, in each worker — replaces its
    /// callbacks; within one run, a name declared twice is kept twice.
    #[test]
    fn a_class_body_run_again_replaces_its_callbacks() {
        let class = "CallbackDeclarationProbe";
        for _ in 0..3 {
            let declaration = Declaration::begin(class, ModelCallbacks::default());
            register_callback(class, "before_save", "normalize");
            register_callback(class, "before_save", "normalize");
            register_callback(class, "after_create", "announce");
            declaration.install();
        }
        let callbacks = registered(class);
        assert_eq!(callbacks.before_save, vec!["normalize", "normalize"]);
        assert_eq!(callbacks.after_create, vec!["announce"]);

        // A body that fails half-way changes nothing.
        let declaration = Declaration::begin(class, ModelCallbacks::default());
        register_callback(class, "before_save", "half");
        drop(declaration);
        assert_eq!(
            registered(class).before_save,
            vec!["normalize", "normalize"]
        );

        // Outside a declaration, a callback is added to the registered list.
        register_callback(class, "after_create", "late");
        assert_eq!(registered(class).after_create, vec!["announce", "late"]);
    }
}
