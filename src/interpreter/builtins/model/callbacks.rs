//! Lifecycle callbacks for models.

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

/// Register a callback for a model class.
///
/// Once per name and kind, as Rails does: the class body runs again on every
/// hot reload, in every worker, against this process-wide registry, and a
/// `--dev` server used to append each callback again each time — after a day
/// of edits, one `save` ran its `before_save` thousands of times.
pub fn register_callback(class_name: &str, callback_type: &str, method_name: &str) {
    MODEL_REGISTRY.write(|registry| {
        let metadata = registry.entry(class_name.to_string()).or_default();
        let callbacks = &mut metadata.callbacks;
        let list = match callback_type {
            "before_save" => &mut callbacks.before_save,
            "after_save" => &mut callbacks.after_save,
            "before_create" => &mut callbacks.before_create,
            "after_create" => &mut callbacks.after_create,
            "before_update" => &mut callbacks.before_update,
            "after_update" => &mut callbacks.after_update,
            "before_delete" => &mut callbacks.before_delete,
            "after_delete" => &mut callbacks.after_delete,
            _ => return,
        };
        if !list.iter().any(|name| name == method_name) {
            list.push(method_name.to_string());
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A class body run again — a hot reload, in each worker — registers its
    /// callbacks once, not once per run.
    #[test]
    fn a_callback_registered_again_is_kept_once() {
        let class = "CallbackDedupProbe";
        for _ in 0..3 {
            register_callback(class, "before_save", "normalize");
            register_callback(class, "before_save", "stamp");
            register_callback(class, "after_create", "announce");
        }
        let (before_save, after_create) = MODEL_REGISTRY.read(|registry| {
            let meta = registry.get(class).expect("registered");
            (
                meta.callbacks.before_save.clone(),
                meta.callbacks.after_create.clone(),
            )
        });
        assert_eq!(before_save, vec!["normalize", "stamp"]);
        assert_eq!(after_create, vec!["announce"]);
    }
}
