open Syntax.Int.LF

val dump : bool ref

val dump_subord : unit -> unit
val dump_typesubord : unit -> unit

(* thin (cO, cD) (tP, cPsi)
 *
 * tP must be atomic, i.e. tP = Atom(loc, a, spine)
 *
 * Returns a ``thinning substitution'' that excludes parts of cPsi that, by (in)subordination,
 *  cannot appear in terms of type tP.
 *
 * If all parts of cPsi are potentially relevant in tP, then `thin' behaves as
 *  Substitution.identity.
 *)
val thin : (mctx * mctx) -> (typ * dctx) -> (sub * dctx)
