use std::sync::{Arc, Mutex};
use pkms_core::MarkdownDoc;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("invalid document update")]
    InvalidUpdate,
    #[error("text range is invalid")]
    InvalidRange,
}

impl From<pkms_core::CoreError> for FfiError {
    fn from(value: pkms_core::CoreError) -> Self {
        match value {
            pkms_core::CoreError::InvalidDocumentUpdate => Self::InvalidUpdate,
            _ => Self::InvalidRange,
        }
    }
}

#[derive(uniffi::Object)]
pub struct SharedMarkdownDoc {
    inner: Mutex<MarkdownDoc>,
}

#[uniffi::export]
impl SharedMarkdownDoc {
    #[uniffi::constructor]
    pub fn new(client_id: u64) -> Arc<Self> {
        Arc::new(Self { inner: Mutex::new(MarkdownDoc::new(client_id)) })
    }

    pub fn text(&self) -> String {
        self.inner.lock().expect("document mutex poisoned").text()
    }

    pub fn insert(&self, index_utf16: u32, value: String) -> Result<Vec<u8>, FfiError> {
        self.inner.lock().expect("document mutex poisoned")
            .insert(index_utf16, &value).map_err(Into::into)
    }

    pub fn delete(&self, index_utf16: u32, length_utf16: u32) -> Result<Vec<u8>, FfiError> {
        self.inner.lock().expect("document mutex poisoned")
            .delete(index_utf16, length_utf16).map_err(Into::into)
    }

    pub fn apply_update(&self, update: Vec<u8>) -> Result<String, FfiError> {
        self.inner.lock().expect("document mutex poisoned")
            .apply_update(&update).map_err(Into::into)
    }

    pub fn snapshot(&self) -> Vec<u8> {
        self.inner.lock().expect("document mutex poisoned").snapshot()
    }

    pub fn state_vector(&self) -> Vec<u8> {
        self.inner.lock().expect("document mutex poisoned").state_vector()
    }
}
