(* -*- coding: utf-8; indent-tabs-mode: nil; -*- *)

(** Substitutions

    @author Renaud Germain
    @author Brigitte Pientka
*)

open Syntax.Int



(**************************)
(* Explicit Substitutions *)
(**************************)

val id       : sub
val shift    : sub
val invShift : sub

val bvarSub  : int      -> sub -> front
val frontSub : front    -> sub -> front
val decSub   : typ_decl -> sub -> typ_decl
val comp     : sub -> sub -> sub
val dot1     : sub -> sub
val invDot1  : sub -> sub

val isPatSub : sub -> bool



(***************************)
(* Inverting Substitutions *)
(***************************)

val invert     : sub -> sub
val strengthen : sub -> dctx -> dctx
val isId       : sub -> bool

val compInv    : sub -> sub -> sub
