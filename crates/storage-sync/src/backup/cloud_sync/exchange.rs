//! Bounded GET/conditional-PUT exchange, driven by an explicit operation or a
//! future configuration-change scheduler. This module never starts a request.
use super::*;

/// Only a successful provider read constructs these. Network/TLS/permission
/// errors must return an error, never Missing. Present requires a strong ETag.
pub enum RemoteRead {
    Missing,
    Present {
        etag: EntityTag,
        ciphertext: Vec<u8>,
    },
}
pub struct Exchange {
    pub(super) operation: u128,
    pub(super) local: Document,
    pub(super) original: Document,
    reads: u8,
    pub(super) actor: String,
}
pub enum ExchangeStep {
    Upload(PendingUpload),
    AlreadyCurrent(Acknowledged),
    References(PendingReferences),
}
pub struct PendingReferences {
    pub(super) remote: Document,
    pub(super) etag: EntityTag,
    pub(super) summary: MergeSummary,
}
impl ExchangeStep {
    pub fn summary(&self) -> MergeSummary {
        match self {
            Self::Upload(p) => p.summary(),
            Self::AlreadyCurrent(a) => a.summary(),
            Self::References(p) => p.summary,
        }
    }
    pub fn uploads(&self) -> bool {
        matches!(self, Self::Upload(_))
    }
}
pub struct PendingUpload {
    operation: u128,
    document: Document,
    ciphertext: Vec<u8>,
    condition: PublicationCondition,
    summary: MergeSummary,
}
/// Acknowledgment capability, not a serializable payload or diagnostic record.
/// The driver must create it ONLY after a successful conditional PUT with a
/// strong ETag, or a verified GET whose plaintext already equals the merge.
pub struct Acknowledged {
    pub(super) operation: u128,
    pub(super) document: Document,
    pub(super) etag: EntityTag,
    summary: MergeSummary,
}
impl Acknowledged {
    pub fn summary(&self) -> MergeSummary {
        self.summary
    }
}
impl Exchange {
    pub fn new(proposal: &LocalProposal) -> Self {
        Self {
            operation: proposal.operation,
            local: proposal.document.clone(),
            original: proposal.document.clone(),
            reads: 0,
            actor: proposal.actor.clone(),
        }
    }
    /// A 412 retries from a fresh GET, with the ORIGINAL frozen local changes.
    /// Three attempts bound one operation. A conflict never changes an ETag,
    /// writes local data, creates a new change stamp or starts another request.
    pub fn accept_read(
        &mut self,
        read: RemoteRead,
        password: &[u8],
        now: u64,
    ) -> Result<ExchangeStep> {
        if self.reads >= 3 {
            return Err(SyncError::Changed);
        }
        self.reads += 1;
        let (document, summary, condition) = match read {
            RemoteRead::Missing => (
                self.local.clone(),
                MergeSummary::default(),
                PublicationCondition::CreateOnly,
            ),
            RemoteRead::Present { etag, ciphertext } => {
                let remote =
                    Document::decrypt(&ciphertext, password, self.local.collection(), now)?;
                let (merged, summary) = self.local.merge_candidate(&remote, now)?;
                match merged.validate(now) {
                    Ok(()) => {}
                    Err(SyncError::References) => {
                        return Ok(ExchangeStep::References(PendingReferences {
                            remote,
                            etag,
                            summary,
                        }));
                    }
                    Err(error) => return Err(error),
                }
                let summary = references::summary(&self.original, &merged, summary.conflicts);
                if merged.encode(now)?.as_slice() == remote.encode(now)?.as_slice() {
                    return Ok(ExchangeStep::AlreadyCurrent(Acknowledged {
                        operation: self.operation,
                        document: merged,
                        etag,
                        summary,
                    }));
                }
                (merged, summary, PublicationCondition::Match(etag))
            }
        };
        let ciphertext = document.encrypt(password, now)?;
        Ok(ExchangeStep::Upload(PendingUpload {
            operation: self.operation,
            document,
            ciphertext,
            condition,
            summary,
        }))
    }
}
impl PendingUpload {
    pub(super) fn resolved(
        operation: u128,
        document: Document,
        ciphertext: Vec<u8>,
        etag: EntityTag,
        summary: MergeSummary,
    ) -> Self {
        Self {
            operation,
            document,
            ciphertext,
            condition: PublicationCondition::Match(etag),
            summary,
        }
    }
    pub(super) fn initial(document: Document, ciphertext: Vec<u8>) -> Self {
        Self {
            operation: rand::random(),
            document,
            ciphertext,
            condition: PublicationCondition::CreateOnly,
            summary: MergeSummary::default(),
        }
    }
    pub fn collection(&self) -> &str {
        self.document.collection()
    }
    pub fn ciphertext(&self) -> &[u8] {
        &self.ciphertext
    }
    pub fn condition(&self) -> &PublicationCondition {
        &self.condition
    }
    pub fn summary(&self) -> MergeSummary {
        self.summary
    }
    /// A timeout/aborted PUT has UNKNOWN outcome, not success or confirmed
    /// precondition failure. The driver re-reads before any later publication.
    /// Missing response ETag also requires re-read rather than a fabricated tag.
    pub fn acknowledge(self, etag: EntityTag) -> Acknowledged {
        Acknowledged {
            operation: self.operation,
            document: self.document,
            etag,
            summary: self.summary,
        }
    }
}

#[cfg(test)]
pub(super) fn http_fixture_upload(condition: PublicationCondition) -> PendingUpload {
    PendingUpload {
        operation: 0,
        document: Document::empty("0123456789abcdef0123456789abcdef").unwrap(),
        ciphertext: vec![0x81, 0x93, 0x67],
        condition,
        summary: MergeSummary::default(),
    }
}
