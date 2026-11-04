//! Incremental runtime counts. Never serialized or trusted on checkpoint restore.
use super::{NodeKind, NodeState, TransferNode, TreeStats};

#[derive(Clone, Copy)]
pub(crate) struct Contribution {
    kind: NodeKind,
    state: NodeState,
    size: u64,
    acknowledged: u64,
}
impl From<&TransferNode> for Contribution {
    fn from(node: &TransferNode) -> Self {
        Self {
            kind: node.kind,
            state: node.state,
            size: node.size,
            acknowledged: node.acknowledged,
        }
    }
}

pub(crate) struct Accumulator {
    counts: TreeStats,
    unknown: usize,
    // Keep exact wide totals so subtracting a contribution after saturation
    // produces the same answer as a fresh scan of the remaining nodes.
    total: u128,
    acknowledged: u128,
}
impl Accumulator {
    pub fn new(nodes: &[TransferNode]) -> Self {
        let mut value = Self {
            counts: TreeStats::default(),
            unknown: 0,
            total: 0,
            acknowledged: 0,
        };
        for node in nodes {
            value.apply(node.into(), true);
        }
        value
    }
    fn apply(&mut self, node: Contribution, add: bool) {
        let adjust = |value: &mut usize| {
            if add {
                *value += 1;
            } else {
                *value -= 1;
            }
        };
        match node.kind {
            NodeKind::File => adjust(&mut self.counts.files),
            NodeKind::Directory => adjust(&mut self.counts.directories),
            NodeKind::Unsupported => {}
        }
        match node.state {
            NodeState::Complete => adjust(&mut self.counts.complete),
            NodeState::Failed => adjust(&mut self.counts.failed),
            NodeState::Conflict => adjust(&mut self.counts.conflicts),
            NodeState::Skipped => adjust(&mut self.counts.skipped),
            NodeState::Pending => {}
        }
        if node.kind != NodeKind::File && node.state == NodeState::Failed {
            adjust(&mut self.unknown);
        }
        if add {
            self.total += u128::from(node.size);
            self.acknowledged += u128::from(node.acknowledged);
        } else {
            self.total -= u128::from(node.size);
            self.acknowledged -= u128::from(node.acknowledged);
        }
    }
    pub fn replace(&mut self, before: Contribution, after: Contribution) {
        self.apply(before, false);
        self.apply(after, true);
    }
    pub fn snapshot(&self) -> TreeStats {
        TreeStats {
            total: self.total.min(u128::from(u64::MAX)) as u64,
            acknowledged: self.acknowledged.min(u128::from(u64::MAX)) as u64,
            total_known: self.unknown == 0,
            ..self.counts
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree_transfer::{ConflictDecision, Direction, TreeTransfer};

    fn manifest(count: usize) -> TreeTransfer {
        TreeTransfer {
            version: 1,
            direction: Direction::Upload,
            local: std::env::temp_dir(),
            remote: "/fixture".into(),
            nodes: (0..count)
                .map(|i| TransferNode {
                    relative: format!("{i}"),
                    kind: NodeKind::File,
                    size: 4096,
                    acknowledged: 0,
                    started: false,
                    state: NodeState::Pending,
                    decision: ConflictDecision::Ask,
                    destination_name: None,
                    error: None,
                    default_policy_pending: true,
                })
                .collect(),
        }
    }
    #[test]
    fn transitions_unknown_totals_and_saturation_match_full_scan() {
        let mut plan = manifest(19);
        plan.nodes[0].size = u64::MAX;
        plan.nodes[0].acknowledged = u64::MAX;
        plan.nodes[1].size = u64::MAX;
        plan.nodes[1].acknowledged = u64::MAX;
        let mut stats = Accumulator::new(&plan.nodes);
        assert_eq!(stats.snapshot(), plan.stats());
        let mut seed = 7u64;
        for round in 0..2000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            let i = (seed % plan.nodes.len() as u64) as usize;
            let node = &mut plan.nodes[i];
            let before = Contribution::from(&*node);
            node.kind = match round % 3 {
                0 => NodeKind::File,
                1 => NodeKind::Directory,
                _ => NodeKind::Unsupported,
            };
            node.state = match round % 5 {
                0 => NodeState::Pending,
                1 => NodeState::Complete,
                2 => NodeState::Failed,
                3 => NodeState::Skipped,
                _ => NodeState::Conflict,
            };
            node.size = round;
            node.acknowledged = round / 2;
            stats.replace(before, Contribution::from(&*node));
            assert_eq!(stats.snapshot(), plan.stats(), "transition {round}");
        }
        assert!(stats.snapshot().total < u64::MAX);
    }

    #[test]
    fn large_manifest_statistics_work_sample() {
        use std::{hint::black_box, time::Instant};
        const NODES: usize = 100_000;
        const EVENTS: usize = 128;
        let mut plan = manifest(NODES);
        let start = Instant::now();
        for i in 0..EVENTS {
            plan.nodes[i].acknowledged = i as u64;
            black_box(plan.stats());
        }
        let full_us = start.elapsed().as_micros();
        let expected = plan.stats();
        for node in &mut plan.nodes[..EVENTS] {
            node.acknowledged = 0;
        }
        let start = Instant::now();
        let mut stats = Accumulator::new(&plan.nodes);
        for i in 0..EVENTS {
            let before = Contribution::from(&plan.nodes[i]);
            plan.nodes[i].acknowledged = i as u64;
            stats.replace(before, Contribution::from(&plan.nodes[i]));
            black_box(stats.snapshot());
        }
        let incremental_us = start.elapsed().as_micros();
        assert_eq!(stats.snapshot(), expected);
        println!(
            "{{\"nodes\":{NODES},\"events\":{EVENTS},\"full_node_visits\":{},\"incremental_contributions\":{},\"full_us\":{full_us},\"incremental_including_init_us\":{incremental_us}}}",
            NODES * EVENTS,
            NODES + EVENTS * 2
        );
    }
}
