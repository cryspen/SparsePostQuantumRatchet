module Spec.GF16
open Core_models

/// SPQR's specification of GF(2^16), the field the Reed-Solomon encoder in
/// `src/encoding/` computes over. This is a *specification*, not a model of an
/// external library: nothing outside SPQR implements it, and `src/encoding/gf.rs`
/// is verified against it.
///
/// # Relation to HACL*'s `Spec.GaloisField`
///
/// The reference formalization of binary Galois fields in this ecosystem is
/// <https://github.com/hacl-star/hacl-star/blob/main/specs/Spec.GaloisField.fst>
/// (present locally under `$HACL_HOME/specs/`, though only `$HACL_HOME/lib` is
/// on the include path). The correspondence is:
///
/// | | HACL* `Spec.GaloisField` | this module |
/// |---|---|---|
/// | field | `field = GF: t:inttype{unsigned t} -> irred:uint_t t -> field` | `class galois_field { n; norm; irred; lemma_norm_* }` |
/// | element | `felem f = uint_t f.t SEC` -- a machine integer | `bv n = x:Seq.seq bool{length x == n}` |
/// | addition | `fadd a b = a ^. b` | `gf_add` = pointwise `bool_xor` on lifted bit vectors |
/// | multiplication | `fmul` -- shift-and-add, reduction interleaved per step | `gf_mul x y = poly_reduce (poly_mul x y)` -- carry-less product, then reduce |
/// | irreducible poly | `irred : uint_t t`, the *low n bits*; the x^n term is implicit in `fmul`'s `carry_mask` | `irred : bv (n+1)`, carrying the x^n term explicitly |
/// | bit order | `get_ith_bit x i` takes bit 0 as the most significant | index 0 is the least significant (`poly_mul_x_k` shifts toward higher indices) |
///
/// For GF(2^16) with the polynomial x^16 + x^12 + x^3 + x + 1, HACL* would
/// write `gf U16 (u16 0x100B)`; this module writes the full 17-bit `0x1100B`
/// because `irred` has type `bv (n+1)`.
///
/// Two deliberate departures from HACL*:
///
/// 1. **Bit vectors rather than machine integers.** `gf.rs` multiplies with
///    `pclmulqdq`/`vmull_p64` and a separate Barrett-style `poly_reduce`, so the
///    implementation genuinely has an unreduced intermediate wider than the
///    field. `to_bv` plus a `bv (n+n)` intermediate lets `mul2_unreduced` and
///    `poly_reduce` carry independent postconditions. HACL*'s `fmul` reduces
///    inside the loop and so cannot be factored that way.
/// 2. **`norm` as a field of the class** rather than a derived function, so that
///    `poly_reduce`'s postcondition (`y == norm x`) is stated once and shared by
///    both the accelerated and unaccelerated backends.
///
/// # Trusted surface
///
/// None. Every declaration in this module is a definition or a proved lemma;
/// there is no `assume val` and no `admit ()`. In particular:
///
/// - `norm` is `red`, long division by `irred` one leading coefficient at a
///   time, and the four `lemma_norm_*` obligations of the class are discharged
///   for it. `gf16_mul` is therefore multiplication in
///   GF(2)[X]/(x^16 + x^12 + x^3 + x + 1), and the `to_bv result == gf16_mul ...`
///   postconditions in `gf.rs` say what they appear to say.
/// - `irred` is a `bv 17` built bit by bit, not `to_bv (mk_i16 0x1100b)`. The
///   latter never typechecked on its own terms and only passed under the admit:
///   `0x1100b` is 69643, outside `i16`'s range, and `to_bv (mk_i16 _)` has type
///   `bv 16` where the field requires `bv 17`.
/// - `to_bv` is `Rust_primitives.Integers.get_bit` read into a `Seq.seq bool`,
///   and the lemmas relating it to `^.`, `|.`, `&.`, `<<!` and `cast` are proved
///   from the corresponding `get_bit_*` lemmas of hax's proof-libs. `to_bv` is
///   `opaque_to_smt` so that the interface those lemmas present is the only way
///   in, as it was when they were assumed.
/// - `up_cast_lemma` is restricted to unsigned source *and* target types. Stated
///   for all types it is false -- a signed source is sign-extended, not
///   zero-extended -- and together with `shift_left_bit_select_lemma` it proved
///   `False`. Both of its uses (`u16 -> u32`) are unsigned.
///
/// What is *not* claimed here is that x^16 + x^12 + x^3 + x + 1 is irreducible
/// over GF(2). Nothing in `gf.rs` needs it: reduction modulo a monic polynomial
/// is a ring homomorphism whether or not that polynomial is irreducible, and the
/// only operation whose correctness would need the field structure -- `div_impl`
/// / `const_div`, which invert by raising to the power 2^16 - 2 -- carries no
/// functional postcondition. Adding one means importing irreducibility, which
/// belongs in Lean/Mathlib as a named assumption rather than an `admit ()` here.

(** Boolean Operations **)

let bool_xor (x:bool) (y:bool) : bool =
  match (x,y) with
  | (true, true) -> false
  | (false, false) -> false
  | (true, false) -> true
  | (false, true) -> true

let bool_or (x:bool) (y:bool) : bool = x || y

let bool_and (x:bool) (y:bool) : bool = x && y

let bool_not (x:bool) : bool = not x

(** Sequence Operations **)

(* The basic definition of a sequence as equivalent to a map function *)
let createi #a (len:nat) (f: (i:nat{i < len}) -> a)
  : x:Seq.seq a{Seq.length x == len /\ (forall i. Seq.index x i == f i)}
  = Seq.init len f

let (.[]) #a (x:Seq.seq a) (i:nat{i < Seq.length x}) = Seq.index x i

let map2 #a #b #c (f: a -> b -> c) (x: Seq.seq a) (y: Seq.seq b{Seq.length x == Seq.length y})
  : r:Seq.seq c{Seq.length r == Seq.length x} =
  createi (Seq.length x) (fun i -> f x.[i] y.[i])

(** Bit Vectors **)

type bv (n:nat) = x:Seq.seq bool{Seq.length x == n}

let zero (#n:nat) : bv n = createi n (fun i -> false)

let lift (#n:nat) (x: bv n) (k:nat{k >= n}) : bv k =
  createi k (fun i -> if i < n then x.[i] else false)

let lower1 (#n:pos) (x: bv n{x.[n-1] = false}) : bv (n-1) =
  createi (n-1) (fun i -> x.[i])

let rec lower (#n:nat) (x: bv n) (k:nat{k <= n /\ (forall j. (j >= k /\ j < n) ==> x.[j] = false)}) : bv k =
    if n = k then x
    else lower (lower1 x) k

let bv_eq_intro #n (x y: bv n) :
  Lemma (requires (forall (i:nat). i < n ==> x.[i] = y.[i]))
        (ensures x == y) =
  Seq.lemma_eq_intro x y

let lemma_lift_id (#n:nat) (x: bv n) : Lemma (lift x n == x) =
  bv_eq_intro (lift x n) x

(* Splitting a bit vector at index k into its low k coefficients and the rest *)

let bv_take (#n:nat) (x: bv n) (k:nat{k <= n}) : bv k = createi k (fun i -> x.[i])

let bv_drop (#n:nat) (x: bv n) (k:nat{k <= n}) : bv (n-k) = createi (n-k) (fun i -> x.[i+k])

(** Galois Field Arithmetic **)

(* Addition and Subtraction *)

let max i j = if i < j then j else i

let gf_add #n #m (x: bv n) (y: bv m) : bv (max n m) =
  map2 bool_xor (lift x (max n m)) (lift y (max n m))

let gf_sub #n #m (x: bv n) (y: bv m) : bv (max n m) =
  gf_add x y

let lemma_add_zero (#n:nat) (x: bv n):
  Lemma (gf_add x (zero #n) == x /\ gf_add (zero #n) x == x) =
    bv_eq_intro (gf_add x (zero #n)) x;
    bv_eq_intro (gf_add (zero #n) x) x

let lemma_add_lift (#n:nat) (#k:nat{k >= n}) (x: bv n) (y:bv k):
  Lemma (gf_add x y == gf_add (lift x k) y /\
         gf_add y x == gf_add y (lift x k)) =
    bv_eq_intro (gf_add x y) (gf_add (lift x k) y);
    bv_eq_intro (gf_add y x) (gf_add y (lift x k))

(* Addition of two bit vectors of the same width. `gf_add` lifts both operands
   to the wider of the two; at equal widths that is the identity, and the
   equal-width form is what the reduction proofs below induct over. *)

let bv_xor (#n:nat) (x y: bv n) : bv n = createi n (fun i -> bool_xor x.[i] y.[i])

let lemma_gf_add_bv_xor (#n:nat) (x y: bv n) : Lemma (gf_add x y == bv_xor x y) =
  bv_eq_intro (gf_add x y) (bv_xor x y)

let lemma_bool_xor_eq (a b: bool) : Lemma (bool_xor a b == false <==> a == b) = ()

let lemma_add_cancel (#n:nat) (x y: bv n)
  : Lemma (requires gf_add x y == zero #n) (ensures x == y) =
  lemma_gf_add_bv_xor x y;
  let aux (i:nat{i < n}) : Lemma (x.[i] == y.[i]) =
    assert ((bv_xor x y).[i] == (zero #n).[i]);
    lemma_bool_xor_eq x.[i] y.[i] in
  Classical.forall_intro aux;
  bv_eq_intro x y

(* Polynomial (carry-less) Multiplication *)

let poly_mul_x_k #n (x: bv n) (k:nat) : bv (n+k) =
  createi (n+k) (fun i -> if i < k then false else x.[i-k])

let lemma_mul_x_k_zero (#n:nat) (x: bv n) : Lemma (poly_mul_x_k x 0 == x) =
  bv_eq_intro (poly_mul_x_k x 0) x

let lemma_mul_x_k_compose (#n:nat) (x: bv n) (j k:nat)
  : Lemma (poly_mul_x_k (poly_mul_x_k x j) k == poly_mul_x_k x (j+k)) =
  bv_eq_intro (poly_mul_x_k (poly_mul_x_k x j) k) (poly_mul_x_k x (j+k))

let lemma_split (#n:nat) (x: bv n) (k:nat{k <= n})
  : Lemma (x == gf_add (lift (bv_take x k) n) (poly_mul_x_k (bv_drop x k) k)) =
  bv_eq_intro x (gf_add (lift (bv_take x k) n) (poly_mul_x_k (bv_drop x k) k))

let rec poly_mul_i #n (x: bv n) (y: bv n) (i: nat{i <= n})
  : Tot (bv (n+n)) (decreases i) =
  if i = 0 then zero #(n+n)
  else
    let prev = poly_mul_i x y (i-1) in
    if y.[i-1] then
       gf_add prev (poly_mul_x_k x (i-1))
    else prev

let poly_mul #n (x y: bv n) : bv (n+n) =
  poly_mul_i x y n

(** Reduction modulo a monic polynomial **)

(* `p : bv (n+1)` stands for the polynomial sum_{i<=n} p.[i] X^i; the reduction
   below is long division by `p` and is only a *reduction* when `p` is monic,
   i.e. `p.[n]`. That is the class's obligation on `irred`, not a precondition
   here.

   `red_step p x` cancels the leading coefficient of `x : bv k` (k > n) by
   adding `p * X^(k-1-n)`, then drops the coefficient it just cleared. It is
   written pointwise rather than as `lower1 (gf_add x (poly_mul_x_k p (k-1-n)))`
   so that dropping the top coefficient needs no side condition -- at k-1 the
   two definitions agree, and cancellation at index k-1 is what monicity buys. *)

let red_step (#n:nat) (#k:nat{k > n}) (p: bv (n+1)) (x: bv k) : bv (k-1) =
  createi (k-1) (fun i -> if x.[k-1] && i + n + 1 >= k
                       then bool_xor x.[i] p.[i + n + 1 - k]
                       else x.[i])

let rec red (#n:nat) (p: bv (n+1)) (#k:nat) (x: bv k) : Tot (bv n) (decreases k) =
  if k <= n then lift x n else red p (red_step p x)

let lemma_red_small (#n:nat) (p: bv (n+1)) (#k:nat{k <= n}) (x: bv k)
  : Lemma (red p x == lift x n) = ()

let lemma_red_idem (#n:nat) (p: bv (n+1)) (x: bv n) : Lemma (red p x == x) =
  lemma_lift_id x

let lemma_red_step_no_top (#n:nat) (#k:nat{k > n}) (p: bv (n+1)) (x: bv k)
  : Lemma (requires x.[k-1] == false) (ensures red_step p x == lower1 x) =
  bv_eq_intro (red_step p x) (lower1 x)

let lemma_red_no_top (#n:nat) (#k:pos) (p: bv (n+1)) (x: bv k)
  : Lemma (requires x.[k-1] == false) (ensures red p x == red p (lower1 x)) =
  if k <= n then bv_eq_intro (lift x n) (lift (lower1 x) n)
  else lemma_red_step_no_top p x

let rec lemma_red_lift (#n:nat) (p: bv (n+1)) (#k:nat) (x: bv k) (j:nat{j >= k})
  : Lemma (ensures red p (lift x j) == red p x) (decreases j) =
  if j = k then lemma_lift_id x
  else begin
    let y : bv j = lift x j in
    assert (y.[j-1] == false);
    lemma_red_no_top p y;
    bv_eq_intro (lower1 y) (lift x (j-1));
    lemma_red_lift p x (j-1)
  end

(* Reduction is additive: it is F2-linear, so it commutes with `bv_xor`. *)

let rec lemma_red_xor (#n:nat) (p: bv (n+1)) (#k:nat) (x y: bv k)
  : Lemma (ensures red p (bv_xor x y) == bv_xor (red p x) (red p y)) (decreases k) =
  if k <= n then
    bv_eq_intro (lift (bv_xor x y) n) (bv_xor (lift x n) (lift y n))
  else begin
    bv_eq_intro (red_step p (bv_xor x y)) (bv_xor (red_step p x) (red_step p y));
    lemma_red_xor p (red_step p x) (red_step p y)
  end

let lemma_red_add (#n:nat) (p: bv (n+1)) (#m #o:nat) (x: bv m) (y: bv o)
  : Lemma (red p (gf_add x y) == gf_add (red p x) (red p y)) =
  let k : nat = max m o in
  let lx : bv k = lift x k in
  let ly : bv k = lift y k in
  bv_eq_intro (gf_add x y) (bv_xor lx ly);
  lemma_red_lift p x k;
  lemma_red_lift p y k;
  lemma_red_xor p lx ly;
  lemma_gf_add_bv_xor (red p x) (red p y)

let lemma_red_split (#n:nat) (p: bv (n+1)) (#m:nat) (x: bv m) (k:nat{k <= m})
  : Lemma (red p x ==
           gf_add (red p (bv_take x k)) (red p (poly_mul_x_k (bv_drop x k) k))) =
  lemma_split x k;
  lemma_red_add p (lift (bv_take x k) m) (poly_mul_x_k (bv_drop x k) k);
  lemma_red_lift p (bv_take x k) m

(* Reduction commutes with multiplication by X, and hence by X^k. *)

let rec lemma_red_shift1 (#n:nat) (p: bv (n+1)) (#m:nat) (x: bv m)
  : Lemma (ensures red p (poly_mul_x_k x 1) == red p (poly_mul_x_k (red p x) 1))
          (decreases m) =
  if m <= n then begin
    bv_eq_intro (poly_mul_x_k (lift x n) 1) (lift (poly_mul_x_k x 1) (n+1));
    lemma_red_lift p (poly_mul_x_k x 1) (n+1)
  end else begin
    bv_eq_intro (poly_mul_x_k (red_step p x) 1) (red_step p (poly_mul_x_k x 1));
    lemma_red_shift1 p (red_step p x)
  end

let rec lemma_red_shift (#n:nat) (p: bv (n+1)) (#m:nat) (x: bv m) (k:nat)
  : Lemma (ensures red p (poly_mul_x_k x k) == red p (poly_mul_x_k (red p x) k))
          (decreases k) =
  if k = 0 then begin
    lemma_mul_x_k_zero x;
    lemma_mul_x_k_zero (red p x);
    lemma_red_idem p (red p x)
  end else begin
    lemma_mul_x_k_compose x (k-1) 1;
    lemma_mul_x_k_compose (red p x) (k-1) 1;
    lemma_red_shift1 p (poly_mul_x_k x (k-1));
    lemma_red_shift p x (k-1);
    lemma_red_shift1 p (poly_mul_x_k (red p x) (k-1))
  end

(* A monic polynomial reduces to zero modulo itself: the single `red_step`
   available at width n+1 cancels every coefficient. *)

let lemma_red_self (#n:nat) (p: bv (n+1))
  : Lemma (requires p.[n] == true) (ensures red p p == zero #n) =
  bv_eq_intro (red_step p p) (zero #n);
  lemma_red_idem p (zero #n)

let rec lemma_red_zero (#n:nat) (p: bv (n+1)) (k:nat)
  : Lemma (ensures red p (zero #k) == zero #n) (decreases k) =
  if k <= n then bv_eq_intro (lift (zero #k) n) (zero #n)
  else begin
    lemma_red_no_top p (zero #k);
    bv_eq_intro (lower1 (zero #k)) (zero #(k-1));
    lemma_red_zero p (k-1)
  end

let lemma_red_self_mul_x_k (#n:nat) (p: bv (n+1)) (k:nat)
  : Lemma (requires p.[n] == true) (ensures red p (poly_mul_x_k p k) == zero #n) =
  lemma_red_shift p p k;
  lemma_red_self p;
  bv_eq_intro (poly_mul_x_k (zero #n) k) (zero #(n+k));
  lemma_red_zero p (n+k)

(* Galois Field Assumptions *)

class galois_field = {
      n: nat;
      norm: #k:nat -> bv k -> bv n;
      irred: p:bv (n+1){p.[n] /\ norm p == zero #n};
      lemma_norm_lower1: #m:pos -> (x: bv m) -> Lemma(x.[m-1] = false ==> norm x == norm (lower1 x));
      lemma_norm_lift: (#m:nat{m <= n}) -> (x: bv m) -> Lemma(norm x == lift x n);
      lemma_norm_add: (#m: nat) -> (#o: nat) -> (x: bv m) -> (y: bv o) -> Lemma(norm (gf_add x y) = gf_add (norm x) (norm y));
      lemma_norm_mul_x_k: (#m: nat) -> (x: bv m) -> (k:nat) -> Lemma(norm (poly_mul_x_k x k) == norm (poly_mul_x_k (norm x) k));
}

(* Reduction *)

let poly_reduce (#gf: galois_field) (#m:nat) (x:bv m)
           : y:bv n{y == norm x} = norm x

let gf_mul (#gf: galois_field) (x:bv n) (y: bv n) : bv n =
  poly_reduce (poly_mul x y)

(* Lemmas *)
let rec lemma_norm_zero (#gf: galois_field) (k:nat):
  Lemma (gf.norm (zero #k) == zero #gf.n) =
    if k <= gf.n then (
      gf.lemma_norm_lift (zero #k);
      bv_eq_intro (lift (zero #k) n) (zero #n))
    else (
      assert (k > 0);
      let zero_k_minus_1 = lower1 (zero #k) in
      gf.lemma_norm_lower1 (zero #k);
      lemma_norm_zero #gf (k-1);
      bv_eq_intro (lower1 (zero #k)) (zero #(k-1))
    )

let lemma_norm_irred_mul_x_k (#gf: galois_field) (k:nat):
  Lemma (gf.norm (poly_mul_x_k irred k) == zero #gf.n) =
    lemma_norm_mul_x_k irred k;
    bv_eq_intro (poly_mul_x_k zero k) (zero #(n+k));
    lemma_norm_zero #gf (n+k)

let rec lemma_norm_lower (#gf: galois_field) (m:nat) (x:bv m):
  Lemma
    (requires (m >= gf.n /\ (forall j. (j >= n /\ j < m) ==> x.[j] = false)))
    (ensures (gf.norm (lower x n) == gf.norm x)) =
    if n = m then ()
    else (
      lemma_norm_lower1 x;
      lemma_norm_lower #gf (m-1) (lower1 x)
    )

(** Integers as Bit Vectors **)

(* `to_bv` reads a machine integer's two's-complement bit pattern, least
   significant bit at index 0, out of hax's `Rust_primitives.Integers.get_bit`.
   It is `opaque_to_smt` -- like `get_bit` itself -- so that the lemmas below
   remain the only way to relate it to integer operations. *)

[@@ "opaque_to_smt"]
let to_bv #t (u: int_t t) : bv (bits t) =
  createi (bits t) (fun i -> get_bit u (sz i) = 1)

let lemma_to_bv_index #t (u: int_t t) (i:nat{i < bits t})
  : Lemma ((to_bv u).[i] == (get_bit u (sz i) = 1))
          [SMTPat ((to_bv u).[i])] =
  reveal_opaque (`%to_bv) (to_bv #t)

(* Lemmas relating integer operations to bit-vector operations *)

let zero_lemma #t:
  Lemma (to_bv ( mk_int #t 0 ) == zero #(bits t)) =
  let aux (i:usize{v i < bits t}) : Lemma (get_bit (mk_int #t 0) i == 0) =
    Rust_primitives.BitVectors.get_bit_pow2_minus_one #t 0 i in
  Classical.forall_intro aux;
  bv_eq_intro (to_bv (mk_int #t 0)) (zero #(bits t))

let xor_lemma #t (x: int_t t) (y: int_t t):
  Lemma (to_bv ( x  ^. y) == map2 bool_xor (to_bv x) (to_bv y)) =
  bv_eq_intro (to_bv (x ^. y)) (map2 bool_xor (to_bv x) (to_bv y))

let or_lemma #t (x: int_t t) (y: int_t t):
  Lemma (to_bv ( x  |. y) == map2 bool_or (to_bv x) (to_bv y)) =
  bv_eq_intro (to_bv (x |. y)) (map2 bool_or (to_bv x) (to_bv y))

let and_lemma #t (x: int_t t) (y: int_t t):
  Lemma (to_bv ( x  &. y) == map2 bool_and (to_bv x) (to_bv y)) =
  bv_eq_intro (to_bv (x &. y)) (map2 bool_and (to_bv x) (to_bv y))

let shift_left_lemma #t #t' (x: int_t t) (y: int_t t'):
  Lemma
    (requires (v y >= 0 /\ v y < bits t))
    (ensures to_bv ( x  <<! y) ==
             createi (bits t) (fun i -> if i < v y then false else (to_bv x).[i - v y])) =
  bv_eq_intro (to_bv (x <<! y))
              (createi (bits t) (fun i -> if i < v y then false else (to_bv x).[i - v y]))

(* Zero-extension. Stated for *unsigned* source and target only: a signed source
   is sign-extended, so the general form is false, and taken together with
   `shift_left_bit_select_lemma` it proves `False`. Both uses are u16 -> u32. *)

let up_cast_lemma (#t:inttype{unsigned t})
                  (#t':inttype{unsigned t' /\ bits t' >= bits t})
                  (x:int_t t{range (v x) t'}):
  Lemma (to_bv (cast (x <: int_t t) <: int_t t') == lift (to_bv x) (bits t')) =
  bv_eq_intro (to_bv (cast (x <: int_t t) <: int_t t')) (lift (to_bv x) (bits t'))

(* Right shift, truncating cast and low-bit mask, for the byte-wise reduction *)

let shift_right_lemma (#t:inttype{unsigned t}) #t' (x: int_t t) (y: int_t t'):
  Lemma
    (requires (v y >= 0 /\ v y < bits t))
    (ensures to_bv ( x  >>! y) ==
             createi (bits t) (fun i -> if i + v y < bits t then (to_bv x).[i + v y] else false)) =
  bv_eq_intro (to_bv (x >>! y))
              (createi (bits t) (fun i -> if i + v y < bits t then (to_bv x).[i + v y] else false))

#push-options "--z3rlimit 100"
let cast_truncate_lemma (#t:inttype) (#t':inttype{bits t' <= bits t}) (x: int_t t):
  Lemma (to_bv (cast (x <: int_t t) <: int_t t') == bv_take (to_bv x) (bits t')) =
  bv_eq_intro (to_bv (cast (x <: int_t t) <: int_t t')) (bv_take (to_bv x) (bits t'))
#pop-options

let mask_lemma (#t:inttype) (n:nat{pow2 n - 1 <= maxint t}) (x: int_t t):
  Lemma (to_bv (x &. mk_int #t (pow2 n - 1)) ==
         createi (bits t) (fun i -> if i < n then (to_bv x).[i] else false)) =
  let aux (j:usize{v j < bits t})
    : Lemma (get_bit (mk_int #t (pow2 n - 1)) j == (if v j < n then 1 else 0)) =
    Rust_primitives.BitVectors.get_bit_pow2_minus_one #t n j in
  Classical.forall_intro aux;
  bv_eq_intro (to_bv (x &. mk_int #t (pow2 n - 1)))
              (createi (bits t) (fun i -> if i < n then (to_bv x).[i] else false))

(* Lemmas linking integer arithmetic to bit-vector operations *)

let lemma_maxint_pos (t:inttype) : Lemma (maxint t >= 1) =
  FStar.Math.Lemmas.pow2_le_compat (bits t) 1;
  FStar.Math.Lemmas.pow2_le_compat (bits t - 1) 1

let lemma_bit_zero #t (j: usize{v j < bits t}) : Lemma (get_bit (mk_int #t 0) j == 0) =
  assert_norm (pow2 0 - 1 == 0);
  Rust_primitives.BitVectors.get_bit_pow2_minus_one #t 0 j

let lemma_bit_mask #t #t' (x: int_t t) (i: int_t t'{v i >= 0 /\ v i < bits t})
                          (j: usize{v j < bits t})
  : Lemma (get_bit (x &. (mk_int #t 1 <<! i)) j ==
           (if v j = v i then get_bit x j else 0)) =
  lemma_maxint_pos t;
  assert_norm (pow2 1 - 1 == 1);
  if v j >= v i
  then Rust_primitives.BitVectors.get_bit_pow2_minus_one #t 1 (sz (v j - v i))
  else ()

let shift_left_bit_select_lemma #t #t' (x: int_t t) (i: int_t t'{v i >= 0 /\ v i < bits t}):
  Lemma (((x &. (mk_int #t 1 <<! i)) == mk_int #t 0) <==>
         ((to_bv x).[v i] == false)) =
  let m : int_t t = mk_int #t 1 <<! i in
  Classical.forall_intro (lemma_bit_mask x i);
  Classical.forall_intro (lemma_bit_zero #t);
  introduce (x &. m) == mk_int #t 0 ==> (to_bv x).[v i] == false
  with _. (lemma_bit_mask x i (sz (v i)); lemma_bit_zero #t (sz (v i)));
  introduce (to_bv x).[v i] == false ==> (x &. m) == mk_int #t 0
  with _. lemma_int_t_eq_via_bits (x &. m) (mk_int #t 0)

(* GF16 Lemmas *)

let up_cast_shift_left_lemma (#t':inttype) (x: u16) (shift: int_t t'{v shift >= 0 /\ v shift < 16}):
  Lemma (to_bv ((cast x <: u32) <<! shift) ==
         lift (poly_mul_x_k (to_bv x) (v shift)) 32) =
  up_cast_lemma #U16 #U32 x;
  shift_left_lemma #U32 #t' (cast x <: u32) shift;
  bv_eq_intro (to_bv ((cast x <: u32) <<! shift))
              (lift (poly_mul_x_k (to_bv x) (v shift)) 32)

(* Reading a byte out of a 32-bit word: shift it down and truncate. *)

#push-options "--fuel 0 --ifuel 1 --z3rlimit 50"
let byte_at_lemma (x: u32) (k: i32{v k >= 0 /\ v k <= 24})
  : Lemma (to_bv (cast (x >>! k) <: u8) == bv_take (bv_drop (to_bv x) (v k)) 8) =
  shift_right_lemma #U32 x k;
  cast_truncate_lemma #U32 #U8 (x >>! k);
  bv_eq_intro (to_bv (cast (x >>! k) <: u8)) (bv_take (bv_drop (to_bv x) (v k)) 8)

(* `usize` is 32 or 64 bits wide, so routing a u32 through it and truncating to
   a byte loses nothing, and masking with 0xFF before that truncation is
   redundant. *)

let lemma_pow2_usize (_:unit) : Lemma (pow2 32 <= pow2 (bits USIZE)) =
  FStar.Math.Lemmas.pow2_le_compat (bits USIZE) 32

let cast_via_usize_lemma (x: u32) : Lemma ((cast (cast x <: usize) <: u8) == (cast x <: u8)) =
  lemma_pow2_usize ();
  FStar.Math.Lemmas.small_mod (v x) (pow2 (bits USIZE))

let cast_mask_byte_lemma (x: usize)
  : Lemma (v (x &. mk_usize 255) < 256 /\ (cast (x &. mk_usize 255) <: u8) == (cast x <: u8)) =
  assert_norm (pow2 8 == 256);
  logand_mask_lemma x 8;
  FStar.Math.Lemmas.lemma_mod_mod (v x % 256) (v x) 256

let top_byte_index_lemma (x: u32)
  : Lemma (let j : usize = cast (x >>! mk_i32 24) <: usize in
           v j < 256 /\ to_bv (cast j <: u8) == bv_drop (to_bv x) 24) =
  let s = x >>! mk_i32 24 in
  lemma_pow2_usize ();
  FStar.Math.Lemmas.small_mod (v s) (pow2 (bits USIZE));
  cast_via_usize_lemma s;
  byte_at_lemma x (mk_i32 24);
  bv_eq_intro (bv_take (bv_drop (to_bv x) 24) 8) (bv_drop (to_bv x) 24)

let mid_byte_index_lemma (x: u32)
  : Lemma (let j : usize = (cast (x >>! mk_i32 16) <: usize) &. mk_usize 255 in
           v j < 256 /\ to_bv (cast j <: u8) == bv_take (bv_drop (to_bv x) 16) 8) =
  let s = x >>! mk_i32 16 in
  cast_mask_byte_lemma (cast s <: usize);
  cast_via_usize_lemma s;
  byte_at_lemma x (mk_i32 16)
#pop-options

let xor_is_gf_add_lemma #t (x y: int_t t):
    Lemma (to_bv (x ^. y) == gf_add (to_bv x) (to_bv y)) =
    xor_lemma x y;
    bv_eq_intro (to_bv (x ^. y)) (gf_add (to_bv x) (to_bv y))


(* GF16 Implementation *)

(* x^16 + x^12 + x^3 + x + 1, i.e. 0x1100b == 2^16 + 2^12 + 2^3 + 2^1 + 2^0.
   See the table this constant is taken from, cited at `gf.rs`'s `POLY`. *)

let gf16_poly : bv (16+1) =
  createi 17 (fun i -> i = 0 || i = 1 || i = 3 || i = 12 || i = 16)

let gf16_norm (#k:nat) (x: bv k) : bv 16 = red #16 gf16_poly x

(* The 32-bit constant the reduction shifts is the polynomial, zero-extended *)

#push-options "--z3rlimit 200"
let lemma_poly_bit (i:nat{i < 32})
  : Lemma ((to_bv (mk_u32 0x1100b)).[i] == (lift gf16_poly 32).[i]) =
  reveal_opaque (`%to_bv) (to_bv #U32);
  reveal_opaque (`%get_bit) (get_bit #U32);
  if i = 0 then assert_norm (get_bit_nat 69643 0 == 1)
  else if i = 1 then assert_norm (get_bit_nat 69643 1 == 1)
  else if i = 2 then assert_norm (get_bit_nat 69643 2 == 0)
  else if i = 3 then assert_norm (get_bit_nat 69643 3 == 1)
  else if i = 4 then assert_norm (get_bit_nat 69643 4 == 0)
  else if i = 5 then assert_norm (get_bit_nat 69643 5 == 0)
  else if i = 6 then assert_norm (get_bit_nat 69643 6 == 0)
  else if i = 7 then assert_norm (get_bit_nat 69643 7 == 0)
  else if i = 8 then assert_norm (get_bit_nat 69643 8 == 0)
  else if i = 9 then assert_norm (get_bit_nat 69643 9 == 0)
  else if i = 10 then assert_norm (get_bit_nat 69643 10 == 0)
  else if i = 11 then assert_norm (get_bit_nat 69643 11 == 0)
  else if i = 12 then assert_norm (get_bit_nat 69643 12 == 1)
  else if i = 13 then assert_norm (get_bit_nat 69643 13 == 0)
  else if i = 14 then assert_norm (get_bit_nat 69643 14 == 0)
  else if i = 15 then assert_norm (get_bit_nat 69643 15 == 0)
  else if i = 16 then assert_norm (get_bit_nat 69643 16 == 1)
  else if i = 17 then assert_norm (get_bit_nat 69643 17 == 0)
  else if i = 18 then assert_norm (get_bit_nat 69643 18 == 0)
  else if i = 19 then assert_norm (get_bit_nat 69643 19 == 0)
  else if i = 20 then assert_norm (get_bit_nat 69643 20 == 0)
  else if i = 21 then assert_norm (get_bit_nat 69643 21 == 0)
  else if i = 22 then assert_norm (get_bit_nat 69643 22 == 0)
  else if i = 23 then assert_norm (get_bit_nat 69643 23 == 0)
  else if i = 24 then assert_norm (get_bit_nat 69643 24 == 0)
  else if i = 25 then assert_norm (get_bit_nat 69643 25 == 0)
  else if i = 26 then assert_norm (get_bit_nat 69643 26 == 0)
  else if i = 27 then assert_norm (get_bit_nat 69643 27 == 0)
  else if i = 28 then assert_norm (get_bit_nat 69643 28 == 0)
  else if i = 29 then assert_norm (get_bit_nat 69643 29 == 0)
  else if i = 30 then assert_norm (get_bit_nat 69643 30 == 0)
  else if i = 31 then assert_norm (get_bit_nat 69643 31 == 0)
  else ()

let lemma_poly_to_bv ()
  : Lemma (to_bv (mk_u32 0x1100b) == lift gf16_poly 32) =
  Classical.forall_intro lemma_poly_bit;
  bv_eq_intro (to_bv (mk_u32 0x1100b)) (lift gf16_poly 32)
#pop-options

let lemma_poly_shifted (i: u32{v i <= 15})
  : Lemma (to_bv ((mk_u32 0x1100b) <<! i) == lift (poly_mul_x_k gf16_poly (v i)) 32) =
  lemma_poly_to_bv ();
  shift_left_lemma (mk_u32 0x1100b) i;
  bv_eq_intro (to_bv ((mk_u32 0x1100b) <<! i)) (lift (poly_mul_x_k gf16_poly (v i)) 32)

(* Reducing the high half of irred * X^i yields its low half: the single step
   the byte-wise reduction table is built from. *)

let lemma_reduce_step (i:nat{i <= 15})
  : Lemma (gf16_norm (poly_mul_x_k (bv_drop (lift (poly_mul_x_k gf16_poly i) 32) 16) 16) ==
           bv_take (lift (poly_mul_x_k gf16_poly i) 32) 16) =
  let p32 : bv 32 = lift (poly_mul_x_k gf16_poly i) 32 in
  lemma_red_split #16 gf16_poly p32 16;
  lemma_red_lift #16 gf16_poly (poly_mul_x_k gf16_poly i) 32;
  lemma_red_self_mul_x_k #16 gf16_poly i;
  lemma_red_idem #16 gf16_poly (bv_take p32 16);
  lemma_add_cancel (bv_take p32 16)
                   (gf16_norm (poly_mul_x_k (bv_drop p32 16) 16))


(* The byte-wise reduction table

   `gf.rs` reduces a 32-bit product one byte at a time against a table indexed
   by that byte. `red_byte c` is what entry `c` must hold: the byte stands for
   the polynomial c * X^16, and the table stores its normal form. *)

let red_byte (c: bv 8) : bv 16 = gf16_norm (poly_mul_x_k c 16)

let lemma_mul_x_k_xor (#n:nat) (x y: bv n) (k:nat)
  : Lemma (poly_mul_x_k (bv_xor x y) k == bv_xor (poly_mul_x_k x k) (poly_mul_x_k y k)) =
  bv_eq_intro (poly_mul_x_k (bv_xor x y) k) (bv_xor (poly_mul_x_k x k) (poly_mul_x_k y k))

let lemma_red_byte_xor (a b: bv 8)
  : Lemma (red_byte (bv_xor a b) == bv_xor (red_byte a) (red_byte b)) =
  lemma_mul_x_k_xor a b 16;
  lemma_red_xor #16 gf16_poly (poly_mul_x_k a 16) (poly_mul_x_k b 16)

let lemma_take_xor (#n:nat) (x y: bv n) (k:nat{k <= n})
  : Lemma (bv_take (bv_xor x y) k == bv_xor (bv_take x k) (bv_take y k)) =
  bv_eq_intro (bv_take (bv_xor x y) k) (bv_xor (bv_take x k) (bv_take y k))

let lemma_red_byte_zero (_:unit) : Lemma (red_byte (zero #8) == zero #16) =
  bv_eq_intro (poly_mul_x_k (zero #8) 16) (zero #24);
  lemma_red_zero #16 gf16_poly 24

let lemma_take_u32_zero (_:unit) : Lemma (bv_take (to_bv (mk_u32 0)) 16 == zero #16) =
  zero_lemma #U32;
  bv_eq_intro (bv_take (to_bv (mk_u32 0)) 16) (zero #16)

(* One entry of the table is built by cancelling the bits of `c` from the top
   down. Cancelling bit `i` adds the polynomial shifted left by `i`, whose high
   byte is the mask applied to `c` and whose low half accumulates into the
   entry. *)

let poly_hi_byte (i:nat{i <= 7}) : bv 8 =
  bv_take (bv_drop (lift (poly_mul_x_k gf16_poly i) 32) 16) 8

let lemma_poly_hi_byte_bits (i:nat{i <= 7}) (j:nat{j < 8})
  : Lemma ((poly_hi_byte i).[j] == (j = i || j + 4 = i)) =
  let pmx : bv (17+i) = poly_mul_x_k gf16_poly i in
  let p : bv 32 = lift pmx 32 in
  assert ((poly_hi_byte i).[j] == (bv_drop p 16).[j]);
  assert ((bv_drop p 16).[j] == p.[j+16]);
  assert (p.[j+16] == (if j+16 < 17+i then pmx.[j+16] else false));
  if j + 16 < 17 + i then begin
    assert (j <= i);
    assert (pmx.[j+16] == gf16_poly.[j+16-i]);
    assert (gf16_poly.[j+16-i] ==
            (j+16-i = 0 || j+16-i = 1 || j+16-i = 3 || j+16-i = 12 || j+16-i = 16))
  end else ()

let lemma_red_byte_hi (i:nat{i <= 7})
  : Lemma (red_byte (poly_hi_byte i) == bv_take (lift (poly_mul_x_k gf16_poly i) 32) 16) =
  let p : bv 32 = lift (poly_mul_x_k gf16_poly i) 32 in
  lemma_reduce_step i;
  bv_eq_intro (poly_mul_x_k (bv_drop p 16) 16) (lift (poly_mul_x_k (poly_hi_byte i) 16) 32);
  lemma_red_lift #16 gf16_poly (poly_mul_x_k (poly_hi_byte i) 16) 32

(* The invariant the table-building loop preserves: adding the shifted
   polynomial to the accumulator and its high byte to `a` leaves
   `red_byte a + low16 out` unchanged, while clearing bit `i` of `a` and
   touching no bit above it. *)

let lemma_reduce_byte_step (a: bv 8) (out: bv 32) (i:nat{i <= 7})
  : Lemma (requires a.[i] == true)
          (ensures (
            let p : bv 32 = lift (poly_mul_x_k gf16_poly i) 32 in
            let a' = bv_xor a (poly_hi_byte i) in
            let out' = bv_xor out p in
            gf_add (red_byte a') (bv_take out' 16) ==
            gf_add (red_byte a) (bv_take out 16) /\
            a'.[i] == false /\
            (forall (j:nat). j > i /\ j < 8 ==> a'.[j] == a.[j]))) =
  let p : bv 32 = lift (poly_mul_x_k gf16_poly i) 32 in
  let m = poly_hi_byte i in
  let a' = bv_xor a m in
  let out' = bv_xor out p in
  Classical.forall_intro (lemma_poly_hi_byte_bits i);
  lemma_red_byte_xor a m;
  lemma_red_byte_hi i;
  lemma_take_xor out p 16;
  lemma_gf_add_bv_xor (red_byte a') (bv_take out' 16);
  lemma_gf_add_bv_xor (red_byte a) (bv_take out 16);
  bv_eq_intro (bv_xor (red_byte a') (bv_take out' 16))
              (bv_xor (red_byte a) (bv_take out 16))

(* The same step on the machine integers the loop manipulates *)

let lemma_poly_hi_byte_int (i: u32{v i <= 7})
  : Lemma (to_bv (cast (((mk_u32 0x1100b) <<! i) >>! mk_i32 16) <: u8) == poly_hi_byte (v i)) =
  let p32 = (mk_u32 0x1100b) <<! i in
  lemma_poly_shifted i;
  shift_right_lemma #U32 p32 (mk_i32 16);
  cast_truncate_lemma #U32 #U8 (p32 >>! mk_i32 16);
  bv_eq_intro (to_bv (cast (p32 >>! mk_i32 16) <: u8)) (poly_hi_byte (v i))

let lemma_reduce_step_int (a: u8) (out: u32) (i: u32{v i <= 7})
  : Lemma (requires (to_bv a).[v i] == true)
          (ensures (
            let p = (mk_u32 0x1100b) <<! i in
            let a' = a ^. (cast (p >>! mk_i32 16) <: u8) in
            let out' = out ^. p in
            gf_add (red_byte (to_bv a')) (bv_take (to_bv out') 16) ==
            gf_add (red_byte (to_bv a)) (bv_take (to_bv out) 16) /\
            (to_bv a').[v i] == false /\
            (forall (j:nat). j > v i /\ j < 8 ==> (to_bv a').[j] == (to_bv a).[j]))) =
  let p = (mk_u32 0x1100b) <<! i in
  let m : u8 = cast (p >>! mk_i32 16) <: u8 in
  lemma_poly_hi_byte_int i;
  lemma_poly_shifted i;
  xor_lemma a m;
  bv_eq_intro (to_bv (a ^. m)) (bv_xor (to_bv a) (poly_hi_byte (v i)));
  xor_lemma out p;
  bv_eq_intro (to_bv (out ^. p)) (bv_xor (to_bv out) (lift (poly_mul_x_k gf16_poly (v i)) 32));
  lemma_reduce_byte_step (to_bv a) (to_bv out) (v i)

let lemma_bit_test (a: u8) (i: u32{v i < 8})
  : Lemma ((((mk_u8 1 <<! i) &. a) == mk_u8 0) <==> ((to_bv a).[v i] == false)) =
  logand_commutative (mk_u8 1 <<! i) a;
  shift_left_bit_select_lemma #U8 #U32 a i

(* Reducing a 32-bit product against the table

   The product is normalised one byte at a time from the top. Each step adds
   the table entry for a byte back in at a lower position, which changes
   nothing modulo the polynomial; after two steps the low 16 bits are the
   normal form, and the two high bytes -- which the implementation leaves
   standing -- are discarded by the truncating cast to u16. *)

let lemma_norm_lift_any (#k:nat) (x: bv k) (j:nat{j >= k})
  : Lemma (gf16_norm (lift x j) == gf16_norm x) =
  lemma_red_lift #16 gf16_poly x j

let lemma_norm_low16 (b: bv 32)
  : Lemma (gf16_norm b ==
           gf_add (bv_take b 16) (gf16_norm (poly_mul_x_k (bv_drop b 16) 16))) =
  lemma_red_split #16 gf16_poly b 16;
  lemma_red_idem #16 gf16_poly (bv_take b 16)

let lemma_norm_hi_bytes (x: bv 16)
  : Lemma (gf16_norm (poly_mul_x_k x 16) ==
           gf_add (red_byte (bv_take x 8)) (gf16_norm (poly_mul_x_k (bv_drop x 8) 24))) =
  let lo : bv 8 = bv_take x 8 in
  let hi : bv 8 = bv_drop x 8 in
  lemma_split x 8;
  lemma_gf_add_bv_xor (lift lo 16) (poly_mul_x_k hi 8);
  lemma_mul_x_k_xor (lift lo 16) (poly_mul_x_k hi 8) 16;
  lemma_red_xor #16 gf16_poly (poly_mul_x_k (lift lo 16) 16)
                              (poly_mul_x_k (poly_mul_x_k hi 8) 16);
  bv_eq_intro (poly_mul_x_k (lift lo 16) 16) (lift (poly_mul_x_k lo 16) 32);
  lemma_norm_lift_any (poly_mul_x_k lo 16) 32;
  lemma_mul_x_k_compose hi 8 16;
  lemma_gf_add_bv_xor (red_byte lo) (gf16_norm (poly_mul_x_k hi 24))

let lemma_norm_red_byte_shift (c: bv 8)
  : Lemma (gf16_norm (poly_mul_x_k (red_byte c) 8) == gf16_norm (poly_mul_x_k c 24)) =
  lemma_red_shift #16 gf16_poly (poly_mul_x_k c 16) 8;
  lemma_mul_x_k_compose c 16 8

#push-options "--z3rlimit 50"
let lemma_poly_reduce_bv (b: bv 32)
  : Lemma (
      let c  : bv 8  = bv_drop b 24 in
      let b1 : bv 32 = gf_add b (lift (poly_mul_x_k (red_byte c) 8) 32) in
      let d' : bv 8  = bv_take (bv_drop b1 16) 8 in
      bv_take (gf_add b1 (lift (red_byte d') 32)) 16 == gf16_norm b) =
  let c  : bv 8  = bv_drop b 24 in
  let rc : bv 16 = red_byte c in
  let s  : bv 32 = lift (poly_mul_x_k rc 8) 32 in
  let b1 : bv 32 = gf_add b s in
  let h  : bv 16 = bv_drop b1 16 in
  let d' : bv 8  = bv_take h 8 in
  let nc : bv 16 = gf16_norm (poly_mul_x_k c 24) in
  bv_eq_intro (bv_drop h 8) c;
  lemma_norm_low16 b1;
  lemma_norm_hi_bytes h;
  lemma_red_add #16 gf16_poly b s;
  lemma_norm_lift_any (poly_mul_x_k rc 8) 32;
  lemma_norm_red_byte_shift c;
  assert (gf16_norm b1 == gf_add (bv_take b1 16) (gf16_norm (poly_mul_x_k h 16)));
  assert (gf16_norm (poly_mul_x_k h 16) == gf_add (red_byte d') nc);
  assert (gf16_norm b1 == gf_add (gf16_norm b) nc);
  lemma_gf_add_bv_xor (bv_take b1 16) (gf_add (red_byte d') nc);
  lemma_gf_add_bv_xor (red_byte d') nc;
  lemma_gf_add_bv_xor (gf16_norm b) nc;
  let b2 : bv 32 = gf_add b1 (lift (red_byte d') 32) in
  let aux (i:nat{i < 16}) : Lemma ((bv_take b2 16).[i] == (gf16_norm b).[i]) =
    assert ((gf16_norm b1).[i] ==
            bool_xor (b1.[i]) (bool_xor ((red_byte d').[i]) (nc.[i])));
    assert ((gf16_norm b1).[i] == bool_xor ((gf16_norm b).[i]) (nc.[i]));
    assert ((bv_take b2 16).[i] == bool_xor (b1.[i]) ((red_byte d').[i]))
  in
  Classical.forall_intro aux;
  bv_eq_intro (bv_take b2 16) (gf16_norm b)
#pop-options

let gf16_irred : p:bv (16+1){p.[16] /\ gf16_norm p == zero #16} =
  lemma_red_self #16 gf16_poly;
  gf16_poly

let gf16_lemma_norm_lower1 (#m:pos) (x: bv m)
  : Lemma (x.[m-1] = false ==> gf16_norm x == gf16_norm (lower1 x)) =
  if x.[m-1] = false then lemma_red_no_top #16 #m gf16_poly x else ()

let gf16_lemma_norm_lift (#m:nat{m <= 16}) (x: bv m)
  : Lemma (gf16_norm x == lift x 16) = lemma_red_small #16 gf16_poly x

let gf16_lemma_norm_add (#m #o:nat) (x: bv m) (y: bv o)
  : Lemma (gf16_norm (gf_add x y) = gf_add (gf16_norm x) (gf16_norm y)) =
  lemma_red_add #16 gf16_poly x y

let gf16_lemma_norm_mul_x_k (#m:nat) (x: bv m) (k:nat)
  : Lemma (gf16_norm (poly_mul_x_k x k) == gf16_norm (poly_mul_x_k (gf16_norm x) k)) =
  lemma_red_shift #16 gf16_poly x k

instance gf16: galois_field = {
  n = 16;
  norm = gf16_norm;
  irred = gf16_irred;
  lemma_norm_lower1 = gf16_lemma_norm_lower1;
  lemma_norm_lift = gf16_lemma_norm_lift;
  lemma_norm_add = gf16_lemma_norm_add;
  lemma_norm_mul_x_k = gf16_lemma_norm_mul_x_k
}

let gf16_mul = gf_mul #gf16
