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
    /// Last locally applied baseline: the shared three-way merge ancestor.
    pub(super) base: Document,
    remote: Option<Document>,
    etag: Option<EntityTag>,
    reads: u8,
    pub(super) resolution: Divergence,
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
            Self::References(p) => p.summary.clone(),
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
        self.summary.clone()
    }
}
impl Exchange {
    pub fn new(proposal: &LocalProposal, base: &Document) -> Self {
        Self {
            operation: proposal.operation,
            local: proposal.document.clone(),
            original: proposal.document.clone(),
            base: base.clone(),
            remote: None,
            etag: None,
            reads: 0,
            resolution: Divergence::Unresolved,
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
        match read {
            RemoteRead::Missing => {
                let document = self.local.clone();
                let ciphertext = document.encrypt(password, now)?;
                Ok(ExchangeStep::Upload(PendingUpload {
                    operation: self.operation,
                    document,
                    ciphertext,
                    condition: PublicationCondition::CreateOnly,
                    summary: MergeSummary::default(),
                }))
            }
            RemoteRead::Present { etag, ciphertext } => {
                let remote =
                    Document::decrypt(&ciphertext, password, self.local.collection(), now)?;
                self.remote = Some(remote.clone());
                self.etag = Some(etag);
                let etag = self.etag.clone().expect("etag stored before rebuild");
                self.rebuild(&remote, &etag, password, now)
            }
        }
    }
    /// Recompute the merge and its review step from the frozen local proposal,
    /// the applied baseline and the last verified remote read, applying any
    /// explicit whole-direction choice. An unresolved both-modified unit keeps
    /// the local side tentatively and is never published (the driver refuses
    /// to confirm such a step); reference repair is only offered once no
    /// unresolved divergence remains, so the direction dialog always comes
    /// first and never re-appears behind a repaired candidate.
    fn rebuild(
        &self,
        remote: &Document,
        etag: &EntityTag,
        password: &[u8],
        now: u64,
    ) -> Result<ExchangeStep> {
        let (merged, summary) =
            self.local
                .merge_candidate(&self.base, remote, now, self.resolution)?;
        match merged.validate(now) {
            Ok(()) => {}
            Err(SyncError::References) if summary.diverged.is_empty() => {
                return Ok(ExchangeStep::References(PendingReferences {
                    remote: remote.clone(),
                    etag: etag.clone(),
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
                etag: etag.clone(),
                summary,
            }));
        }
        let ciphertext = merged.encrypt(password, now)?;
        Ok(ExchangeStep::Upload(PendingUpload {
            operation: self.operation,
            document: merged,
            ciphertext,
            condition: PublicationCondition::Match(etag.clone()),
            summary,
        }))
    }
    /// Apply the user's whole-direction choice to EVERY unit modified on both
    /// sides since the baseline, then recompute the review step. The choice
    /// stays frozen for later 412 re-reads of the same operation.
    pub fn resolve_divergence(
        &mut self,
        direction: Divergence,
        password: &[u8],
        now: u64,
    ) -> Result<ExchangeStep> {
        if direction == Divergence::Unresolved {
            return Err(SyncError::Invalid);
        }
        let (remote, etag) = match (self.remote.clone(), self.etag.clone()) {
            (Some(remote), Some(etag)) => (remote, etag),
            _ => return Err(SyncError::Changed),
        };
        self.resolution = direction;
        self.rebuild(&remote, &etag, password, now)
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
        self.summary.clone()
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
