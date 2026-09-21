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

/// `SortedSet::new()`
val impl_10__new: #v_T: Type0 -> {| i1: Core_models.Cmp.t_Ord v_T |} -> Prims.unit
  -> Prims.Pure (t_SortedSet v_T) Prims.l_True (fun _ -> Prims.l_True)

/// `SortedSet::push`, returning the element's index and the equal element it
/// displaced, if any. Sortedness and deduplication are not stated.
/// <https://docs.rs/sorted-vec/0.8/sorted_vec/struct.SortedSet.html#method.push>
val impl_10__push (#v_T: Type0) {| i1: Core_models.Cmp.t_Ord v_T |} (self: t_SortedSet v_T) (element: v_T)
    : Prims.Pure (t_SortedSet v_T & (usize & Core_models.Option.t_Option v_T))
      Prims.l_True
      (fun _ -> Prims.l_True)
