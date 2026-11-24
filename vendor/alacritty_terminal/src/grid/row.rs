//! Defines the Row type which makes up lines in the grid.

use std::cmp::{max, min};
use std::ops::{Index, IndexMut, Range, RangeFrom, RangeFull, RangeTo, RangeToInclusive};
use std::{ptr, slice};

#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

use crate::grid::GridCell;
#[cfg(feature = "hspterm-history")]
use std::sync::{Arc, OnceLock};

/// Application-owned immutable cold row. Implementations must latch I/O faults;
/// the application must check those faults before publishing terminal state.
#[cfg(feature = "hspterm-history")]
pub trait RowBacking<T>: std::fmt::Debug + Send + Sync {
    fn load(&self) -> Vec<T>;
    fn columns(&self) -> usize;
}

use crate::index::Column;
use crate::term::cell::ResetDiscriminant;

/// A row in the grid.
#[derive(Clone, Debug)]
#[cfg_attr(all(feature = "serde", not(feature = "hspterm-history")), derive(Serialize, Deserialize))]
pub struct Row<T> {
    inner: Vec<T>,
    #[cfg(feature = "hspterm-history")]
    page: Option<Arc<dyn RowBacking<T>>>,
    #[cfg(feature = "hspterm-history")]
    resident: OnceLock<Vec<T>>,
    #[cfg(feature = "hspterm-history")]
    identity: u64,
    #[cfg(feature = "hspterm-history")]
    mutation: u64,

    /// Maximum number of occupied entries.
    ///
    /// This is the upper bound on the number of elements in the row, which have been modified
    /// since the last reset. All cells after this point are guaranteed to be equal.
    pub(crate) occ: usize,
}
impl<T> Default for Row<T> {
    fn default() -> Self { Self::from_vec(Vec::new(), 0) }
}
#[cfg(feature = "hspterm-history")]
fn next_identity() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    // Zero means no reliable identity if the process ever exhausts IDs.
    NEXT.try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1)).unwrap_or(0)
}

impl<T: PartialEq> PartialEq for Row<T> {
    fn eq(&self, other: &Self) -> bool {
        self.cells() == other.cells()
    }
}

impl<T: Default> Row<T> {
    /// Create a new terminal row.
    ///
    /// Ideally the `template` should be `Copy` in all performance sensitive scenarios.
    pub fn new(columns: usize) -> Row<T> {
        debug_assert!(columns >= 1);

        let mut inner: Vec<T> = Vec::with_capacity(columns);

        // This is a slightly optimized version of `std::vec::Vec::resize`.
        unsafe {
            let mut ptr = inner.as_mut_ptr();

            for _ in 1..columns {
                ptr::write(ptr, T::default());
                ptr = ptr.offset(1);
            }
            ptr::write(ptr, T::default());

            inner.set_len(columns);
        }

        Row::from_vec(inner, 0)
    }

    /// Increase the number of columns in the row.
    #[inline]
    pub fn grow(&mut self, columns: usize) {
        if self.len() >= columns {
            return;
        }

        self.cells_mut().resize_with(columns, T::default);
    }

    /// Reduce the number of columns in the row.
    ///
    /// This will return all non-empty cells that were removed.
    pub fn shrink(&mut self, columns: usize) -> Option<Vec<T>>
    where
        T: GridCell,
    {
        if self.len() <= columns {
            return None;
        }

        // Split off cells for a new row.
        let mut new_row = self.cells_mut().split_off(columns);
        let index = new_row.iter().rposition(|c| !c.is_empty()).map_or(0, |i| i + 1);
        new_row.truncate(index);

        self.occ = min(self.occ, columns);

        if new_row.is_empty() { None } else { Some(new_row) }
    }

    /// Reset all cells in the row to the `template` cell.
    #[inline]
    pub fn reset<D>(&mut self, template: &T)
    where
        T: ResetDiscriminant<D> + GridCell,
        D: PartialEq,
    {
        #[cfg(feature = "hspterm-history")]
        { self.identity = next_identity(); self.mutation = 0; }
        #[cfg(feature = "hspterm-history")]
        if self.page.is_some() {
            let columns = self.len();
            self.page = None; self.resident.take();
            self.inner = (0..columns).map(|_| {let mut c = T::default(); c.reset(template); c}).collect();
            self.occ = 0; return;
        }
        debug_assert!(!self.cells().is_empty());

        // Mark all cells as dirty if template cell changed.
        let len = self.len();
        if self.inner[len - 1].discriminant() != template.discriminant() {
            self.occ = len;
        }

        // Reset every dirty cell in the row.
        let occupied = self.occ;
        for item in &mut self.cells_mut()[0..occupied] {
            item.reset(template);
        }

        self.occ = 0;
    }
}

#[allow(clippy::len_without_is_empty)]
impl<T> Row<T> {
    #[inline]
    pub fn from_vec(vec: Vec<T>, occ: usize) -> Row<T> {
        Row { inner: vec, occ,
            #[cfg(feature = "hspterm-history")] page: None,
            #[cfg(feature = "hspterm-history")] resident: OnceLock::new(),
            #[cfg(feature = "hspterm-history")] identity: next_identity(),
            #[cfg(feature = "hspterm-history")] mutation: 0,
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        #[cfg(feature = "hspterm-history")]
        if let Some(page) = &self.page { return page.columns(); }
        self.inner.len()
    }
    #[inline]
    fn cells(&self) -> &Vec<T> {
        #[cfg(feature = "hspterm-history")]
        if let Some(page) = &self.page { return self.resident.get_or_init(|| page.load()); }
        &self.inner
    }
    #[inline]
    fn cells_mut(&mut self) -> &mut Vec<T> {
        #[cfg(feature = "hspterm-history")]
        {
            if let Some(next) = self.mutation.checked_add(1) { self.mutation = next; }
            else { self.identity = next_identity(); self.mutation = 0; }
        }
        #[cfg(feature = "hspterm-history")]
        if let Some(page) = self.page.take() {
            self.inner = self.resident.take().unwrap_or_else(|| page.load());
        }
        &mut self.inner
    }
    /// Numeric provenance only; paging/cache eviction preserve it. Mutable
    /// cell access invalidates it even if the caller later restores old text.
    #[cfg(feature = "hspterm-history")]
    pub fn proof(&self) -> (u64, u64) { (self.identity, self.mutation) }
    #[cfg(feature = "hspterm-history")]
    pub fn is_paged(&self) -> bool { self.page.is_some() }
    #[cfg(feature = "hspterm-history")]
    pub fn evict_cached(&mut self) { self.resident.take(); }
    #[cfg(feature = "hspterm-history")]
    pub fn page_out(&mut self, page: Arc<dyn RowBacking<T>>) {
        debug_assert_eq!(page.columns(), self.len());
        self.page = Some(page); self.inner = Vec::new(); self.resident.take();
    }
    /// Read without filling the grid's viewport cache (search/export).
    #[cfg(feature = "hspterm-history")]
    pub fn owned_cells(&self) -> Vec<T> where T: Clone {
        match &self.page { Some(page) => page.load(), None => self.inner.clone() }
    }
    /// Share the immutable cold page without copying mutable row bookkeeping
    /// or the viewport's decoded cache into a short-lived search/export view.
    #[cfg(feature = "hspterm-history")]
    pub fn frozen_page(&self) -> Option<Arc<dyn RowBacking<T>>> { self.page.clone() }
    #[cfg(feature = "hspterm-history")]
    pub fn resident_cells(&self) -> usize {
        if self.page.is_some() { self.resident.get().map_or(0, Vec::len) } else { self.inner.len() }
    }

    #[inline]
    pub fn last(&self) -> Option<&T> {
        self.cells().last()
    }

    #[inline]
    pub fn last_mut(&mut self) -> Option<&mut T> {
        self.occ = self.len();
        self.cells_mut().last_mut()
    }

    #[inline]
    pub fn append(&mut self, vec: &mut Vec<T>)
    where
        T: GridCell,
    {
        self.occ += vec.len();
        self.cells_mut().append(vec);
    }

    #[inline]
    pub fn append_front(&mut self, mut vec: Vec<T>) {
        self.occ += vec.len();

        vec.append(self.cells_mut());
        *self.cells_mut() = vec;
    }

    /// Check if all cells in the row are empty.
    #[inline]
    pub fn is_clear(&self) -> bool
    where
        T: GridCell,
    {
        self.cells().iter().all(GridCell::is_empty)
    }

    #[inline]
    pub fn front_split_off(&mut self, at: usize) -> Vec<T> {
        self.occ = self.occ.saturating_sub(at);

        let mut split = self.cells_mut().split_off(at);
        std::mem::swap(&mut split, self.cells_mut());
        split
    }
}

impl<'a, T> IntoIterator for &'a Row<T> {
    type IntoIter = slice::Iter<'a, T>;
    type Item = &'a T;

    #[inline]
    fn into_iter(self) -> slice::Iter<'a, T> {
        self.cells().iter()
    }
}

impl<'a, T> IntoIterator for &'a mut Row<T> {
    type IntoIter = slice::IterMut<'a, T>;
    type Item = &'a mut T;

    #[inline]
    fn into_iter(self) -> slice::IterMut<'a, T> {
        self.occ = self.len();
        self.cells_mut().iter_mut()
    }
}

impl<T> Index<Column> for Row<T> {
    type Output = T;

    #[inline]
    fn index(&self, index: Column) -> &T {
        &self.cells()[index.0]
    }
}

impl<T> IndexMut<Column> for Row<T> {
    #[inline]
    fn index_mut(&mut self, index: Column) -> &mut T {
        self.occ = max(self.occ, *index + 1);
        &mut self.cells_mut()[index.0]
    }
}

impl<T> Index<Range<Column>> for Row<T> {
    type Output = [T];

    #[inline]
    fn index(&self, index: Range<Column>) -> &[T] {
        &self.cells()[(index.start.0)..(index.end.0)]
    }
}

impl<T> IndexMut<Range<Column>> for Row<T> {
    #[inline]
    fn index_mut(&mut self, index: Range<Column>) -> &mut [T] {
        self.occ = max(self.occ, *index.end);
        &mut self.cells_mut()[(index.start.0)..(index.end.0)]
    }
}

impl<T> Index<RangeTo<Column>> for Row<T> {
    type Output = [T];

    #[inline]
    fn index(&self, index: RangeTo<Column>) -> &[T] {
        &self.cells()[..(index.end.0)]
    }
}

impl<T> IndexMut<RangeTo<Column>> for Row<T> {
    #[inline]
    fn index_mut(&mut self, index: RangeTo<Column>) -> &mut [T] {
        self.occ = max(self.occ, *index.end);
        &mut self.cells_mut()[..(index.end.0)]
    }
}

impl<T> Index<RangeFrom<Column>> for Row<T> {
    type Output = [T];

    #[inline]
    fn index(&self, index: RangeFrom<Column>) -> &[T] {
        &self.cells()[(index.start.0)..]
    }
}

impl<T> IndexMut<RangeFrom<Column>> for Row<T> {
    #[inline]
    fn index_mut(&mut self, index: RangeFrom<Column>) -> &mut [T] {
        self.occ = self.len();
        &mut self.cells_mut()[(index.start.0)..]
    }
}

impl<T> Index<RangeFull> for Row<T> {
    type Output = [T];

    #[inline]
    fn index(&self, _: RangeFull) -> &[T] {
        &self.cells()[..]
    }
}

impl<T> IndexMut<RangeFull> for Row<T> {
    #[inline]
    fn index_mut(&mut self, _: RangeFull) -> &mut [T] {
        self.occ = self.len();
        &mut self.cells_mut()[..]
    }
}

impl<T> Index<RangeToInclusive<Column>> for Row<T> {
    type Output = [T];

    #[inline]
    fn index(&self, index: RangeToInclusive<Column>) -> &[T] {
        &self.cells()[..=(index.end.0)]
    }
}

impl<T> IndexMut<RangeToInclusive<Column>> for Row<T> {
    #[inline]
    fn index_mut(&mut self, index: RangeToInclusive<Column>) -> &mut [T] {
        self.occ = max(self.occ, *index.end + 1);
        &mut self.cells_mut()[..=(index.end.0)]
    }
}

#[cfg(all(feature = "serde", feature = "hspterm-history"))]
impl<T: Serialize> Serialize for Row<T> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("Row", 2)?;
        state.serialize_field("inner", self.cells())?;
        state.serialize_field("occ", &self.occ)?;
        state.end()
    }
}
#[cfg(all(feature = "serde", feature = "hspterm-history"))]
impl<'de,T: Deserialize<'de>> Deserialize<'de> for Row<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self,D::Error> {
        #[derive(Deserialize)] struct Wire<T> {inner: Vec<T>,occ: usize}
        let wire = Wire::<T>::deserialize(deserializer)?;
        Ok(Self::from_vec(wire.inner,wire.occ))
    }
}
