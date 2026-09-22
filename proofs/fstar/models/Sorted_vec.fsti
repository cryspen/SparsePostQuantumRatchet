module Sorted_vec
#set-options "--fuel 0 --ifuel 1 --z3rlimit 15"
open Core_models
open FStar.Mul

/// `sorted-vec` 0.8.
/// <https://docs.rs/sorted-vec/0.8/sorted_vec/>
///
/// `encoding/polynomial.rs` keeps its interpolation points in a `SortedSet`.
/// Both types are concrete because the extraction reads the underlying `Vec`
/// through `Deref`.

/// A vector kept in ascending order.
/// <https://docs.rs/sorted-vec/0.8/sorted_vec/struct.SortedVec.html>
type t_SortedVec (v_T: Type0) {| i1: Core_models.Cmp.t_Ord v_T |} = {
  f_vec:Alloc.Vec.t_Vec v_T Alloc.Alloc.t_Global
}

/// A `SortedVec` that holds no duplicates.
/// <https://docs.rs/sorted-vec/0.8/sorted_vec/struct.SortedSet.html>
type t_SortedSet (v_T: Type0) {| i1: Core_models.Cmp.t_Ord v_T |} = { f_set:t_SortedVec v_T }

/// `impl Deref for SortedVec { type Target = Vec<T> }`
[@@ FStar.Tactics.Typeclasses.tcinstance]
let impl_5 (#v_T: Type0) (#[FStar.Tactics.Typeclasses.tcresolve ()] i1: Core_models.Cmp.t_Ord v_T)
    : Core_models.Ops.Deref.t_Deref (t_SortedVec v_T) =
  {
    f_Target = Alloc.Vec.t_Vec v_T Alloc.Alloc.t_Global;
    f_deref_pre = (fun (self: t_SortedVec v_T) -> true);
    f_deref_post
    =
    (fun (self: t_SortedVec v_T) (out: Alloc.Vec.t_Vec v_T Alloc.Alloc.t_Global) -> true);
    f_deref = fun (self: t_SortedVec v_T) -> self.f_vec
  }

/// `impl Deref for SortedSet { type Target = SortedVec<T> }`
[@@ FStar.Tactics.Typeclasses.tcinstance]
let impl_13 (#v_T: Type0) (#[FStar.Tactics.Typeclasses.tcresolve ()] i1: Core_models.Cmp.t_Ord v_T)
    : Core_models.Ops.Deref.t_Deref (t_SortedSet v_T) =
  {
    f_Target = t_SortedVec v_T;
    f_deref_pre = (fun (self: t_SortedSet v_T) -> true);
    f_deref_post = (fun (self: t_SortedSet v_T) (out: t_SortedVec v_T) -> true);
    f_deref = fun (self: t_SortedSet v_T) -> self.f_set
  }

/// The elements of a `SortedSet`, reached through its two `Deref`s. Both
/// records are concrete here, so this is a projection, not an assumption.
unfold
let set_seq (#v_T: Type0) {| i1: Core_models.Cmp.t_Ord v_T |} (self: t_SortedSet v_T)
    : Seq.seq v_T = (self.f_set.f_vec)._0

/// `SortedSet::new()` -- `Vec::new()`, so the set is empty.
/// <https://docs.rs/sorted-vec/0.8.6/sorted_vec/struct.SortedSet.html#method.new>
val impl_10__new: #v_T: Type0 -> {| i1: Core_models.Cmp.t_Ord v_T |} -> Prims.unit
  -> Prims.Pure (t_SortedSet v_T) Prims.l_True (fun out -> Seq.length (set_seq out) == 0)

/// `SortedSet::push`, returning the element's index and the equal element it
/// displaced, if any.
/// <https://docs.rs/sorted-vec/0.8.6/sorted_vec/struct.SortedSet.html#method.push>
///
/// The crate documents `push` only as "same as replace, except performance is
/// O(1) when the element belongs at the back", and `replace` as "insert an
/// element into sorted position, returning the order index at which it was
/// placed. If an existing item was found it will be returned." Neither says
/// which of two `Ordering::Equal` elements survives, which is the whole
/// semantics for a type whose `Ord` reads fewer fields than it has. Read off
/// 0.8.6's `SortedSet::push` (src/lib.rs:388-417): the `Equal`-to-last path
/// pops and pushes, and the `< last` path delegates to `replace`, which
/// `mem::swap`s at the index `binary_search` found. Both therefore retain the
/// *new* element and hand back the old one, and the length is unchanged. The
/// sibling `extend`/`find_or_insert` go the other way, so the clause below is
/// specific to `push`.
///
/// Sortedness and deduplication hold but are deliberately not stated: they are
/// only meaningful relative to an input that already has them, which would
/// make this a `requires` that SPQR has no way to discharge while
/// `PolyDecoder::from_pb` is opaque.
val impl_10__push (#v_T: Type0) {| i1: Core_models.Cmp.t_Ord v_T |} (self: t_SortedSet v_T) (element: v_T)
    : Prims.Pure (t_SortedSet v_T & (usize & Core_models.Option.t_Option v_T))
      Prims.l_True
      (fun out ->
        let set, (idx, displaced) = out in
        let before = set_seq self in
        let after = set_seq set in
        v idx < Seq.length after /\
        Seq.index after (v idx) == element /\
        (match displaced with
          | Core_models.Option.Option_None -> Seq.length after == Seq.length before + 1
          | Core_models.Option.Option_Some old ->
            Seq.length after == Seq.length before /\
            Core_models.Cmp.f_cmp #v_T #i1 old element == Core_models.Cmp.Ordering_Equal))

/// `<[T]>::binary_search` returns an index that is in bounds.
///
/// std: "If the value is found then `Result::Ok` is returned, containing the
/// index of the matching element."
/// <https://doc.rust-lang.org/std/primitive.slice.html#method.binary_search>
///
/// hax's `Core_models.Slice.impl__binary_search'` is an upstream `assume val`
/// with `Prims.l_True` on both sides, so the bound has to be stated somewhere.
/// It belongs here rather than at the call site: `SortedSet` reaches the slice
/// through its two `Deref`s and `Vec::as_slice`, which is the only form the
/// extraction produces, and `polynomial.rs::decoded_message` is the only
/// caller.
val lemma_binary_search_ok_in_bounds
      (#v_T: Type0)
      {| i1: Core_models.Cmp.t_Ord v_T |}
      (self: Alloc.Vec.t_Vec v_T Alloc.Alloc.t_Global)
      (x: v_T)
    : Lemma
      (match
          Core_models.Slice.impl__binary_search #v_T
            #i1
            (Alloc.Vec.impl_1__as_slice #v_T #Alloc.Alloc.t_Global self <: t_Slice v_T)
            x
        with
        | Core_models.Result.Result_Ok i ->
          v i < v (Alloc.Vec.impl_1__len #v_T #Alloc.Alloc.t_Global self <: usize)
        | _ -> True)
      [
        SMTPat (Core_models.Slice.impl__binary_search #v_T
              #i1
              (Alloc.Vec.impl_1__as_slice #v_T #Alloc.Alloc.t_Global self <: t_Slice v_T)
              x)
      ]
