(**

   @author Brigitte Pientka
   modified:  Joshua Dunfield

*)

(* Weak Head Normalization,
 * Normalization, and alpha-conversion
 *)

open Syntax.Int.LF
open Syntax.Int
open Substitution


module R = Store.Cid.DefaultRenderer
module T = Store.Cid.Typ

exception Fmvar_not_found
exception FreeMVar of head
exception NonInvertible
exception InvalidLFHole of Loc.t


type mm_res =
    | ResMM of mm_var * msub
    | Result of iterm

let (dprint, _) = Debug.makeFunctions (Debug.toFlags [18])

let rec raiseType cPsi tA = match cPsi with
  | Null -> tA
  | DDec (cPsi', decl) ->
      raiseType cPsi' (PiTyp ((decl, Maybe), tA))

(* Eta-contract elements in substitutions *)
let etaContract tM = begin match tM with
  | Root (_, BVar k, Nil) -> Head (BVar k)
  | Lam  _ as tMn ->
      let rec etaUnroll k tM = begin match tM with
        | Lam (_ , _, tN) ->
            let _ = dprint (fun () -> "etaUnroll k ="  ^ string_of_int k ^ "\n") in
              etaUnroll (k+1) tN
        |  _ ->  let _ = dprint (fun () -> "etaUnroll k ="  ^ string_of_int k ^ "\n") in  (k, tM)
      end in
      let rec etaSpine k tS = begin match (k, tS) with
        | (0, Nil) -> true
        | (k', App(Root(_ , BVar x, Nil), tS')) ->
            if k' = x then etaSpine (k'-1)  tS'
            else false
        | _ -> false (* previously (dprint (fun () -> "[etaSpine] _ ") ; raise (Error.Violation ("etaSpine undefined\n"))) *)
      end in
        begin match etaUnroll 0 tMn with
          | (k, Root( _ , BVar x, tS)) ->
              (let _ = dprint (fun () -> "check etaSpine k ="  ^ string_of_int k ^ "\n") in
                 (if etaSpine k tS && x > k then
                    Head(BVar (x-k))
                  else
                    Obj tMn))
          | _ ->  Obj tMn
        end
  | _  -> Obj tM
 end

(*************************************)
(* Creating new contextual variables *)
(*************************************)
(* newCVar n sW = psi
 *
 *)
let newCVar n (sW) = match n with
  | None -> CInst ((Id.mk_name Id.NoName, ref None, Empty, CTyp sW, ref [], Maybe), MShift 0)
  | Some name -> CInst ((name, ref None, Empty, CTyp sW, ref [], Maybe), MShift 0)

(* newMVar n (cPsi, tA) = newMVarCnstr (cPsi, tA, [])
 *
 * Invariant:
 *
 *       tA =   Atom (a, S)
 *   or  tA =   Pi (x:tB, tB')
 *   but tA =/= TClo (_, _)
 *)


let newMVar n (cPsi, tA) = match n with
  | None -> Inst (Id.mk_name (Id.MVarName (T.gen_var_name tA)), ref None, Empty, MTyp(tA,cPsi), ref [], Maybe)
  | Some name -> Inst (name, ref None, Empty, MTyp(tA,cPsi), ref [], if name.Id.was_generated then Maybe else No)

let newMVar' n (cPsi, tA) = match n with
  | None -> (Id.mk_name (Id.MVarName (T.gen_var_name tA)), ref None, Empty, MTyp(tA,cPsi), ref [], Maybe)
  | Some name -> (name, ref None, Empty, MTyp(tA,cPsi), ref [], if name.Id.was_generated then Maybe else No)

(* newMMVar n (cPsi, tA) = newMVarCnstr (cPsi, tA, [])
 *
 * Invariant:
 *
 *       tA =   Atom (a, S)
 *   or  tA =   Pi (x:tB, tB')
 *   but tA =/= TClo (_, _)
 *)
let newMMVar n (cD, cPsi, tA) = match n with
  (* flatten blocks in cPsi, and create appropriate indices in tA
     together with an appropriate substitution which moves us between
     the flattened cPsi_f and cPsi.

     this will allow to later prune MMVars.
     Tue Dec  1 09:49:06 2009 -bp
   *)
  | None -> (Id.mk_name (Id.MVarName (T.gen_var_name tA)), ref None, cD, MTyp(tA,cPsi), ref [], Maybe)
  | Some name -> (name, ref None, cD, MTyp(tA,cPsi), ref [], if name.Id.was_generated then Maybe else No)

let newMPVar n (cD, cPsi, tA) = match n with
  | None -> (Id.mk_name (Id.PVarName (T.gen_var_name tA)), ref None, cD, PTyp(tA,cPsi), ref [], Maybe)
  | Some name -> (name, ref None, cD, PTyp(tA,cPsi), ref [], if name.Id.was_generated then Maybe else No)


let newMSVar n (cD, cPsi, cPhi)  = match n with
  | None -> (Id.mk_name (Id.SVarName None), ref None, cD, STyp(cPhi, cPsi), ref [], Maybe)
  | Some name -> (name, ref None, cD, STyp(cPhi, cPsi), ref [], if name.Id.was_generated then Maybe else No)
  (* Note : cPsi | - s : cPhi *)

(******************************)
(* Lowering of Meta-Variables *)
(******************************)

(* lowerMVar' cPsi tA[s] = (u, tM), see lowerMVar *)
let rec lowerMVar' cPsi sA' = match sA' with
  | (PiTyp ((decl,_ ), tA'), s') ->
      let (u', tM) = lowerMVar' (DDec (cPsi, LF.decSub decl s')) (tA', LF.dot1 s') in
        (u', Lam (Syntax.Loc.ghost, Id.mk_name Id.NoName, tM))

  | (TClo (tA, s), s') ->
      lowerMVar' cPsi (tA, LF.comp s s')

  | (Atom (loc, a, tS), s') ->
      let u' = newMVar None (cPsi, Atom (loc, a, SClo (tS, s')))  in 
        (u', Root (Syntax.Loc.ghost, MVar (u', LF.id), Nil)) (* cvar * normal *)


(* lowerMVar1 (u, tA[s]), tA[s] in whnf, see lowerMVar *)
and lowerMVar1 u sA = match (u, sA) with
  | (Inst (_n, r, _, MTyp(_,cPsi), _, _), (PiTyp _, _)) ->
      let (u', tM) = lowerMVar' cPsi sA in
        r := Some (INorm tM); (* [| tM / u |] *)
        u'            (* this is the new lowered meta-variable of atomic type *)

  | (_, (TClo (tA, s), s')) ->
      lowerMVar1 u (tA, LF.comp s s')

  | (_, (Atom _, _s)) ->
      u


(* lowerMVar (u:cvar) = u':cvar
 *
 * Invariant:
 *
 *   If    cD = D1, u::tA[cPsi], D2
 *   where tA = PiTyp x1:B1 ... xn:tBn. tP
 *   and   u not subject to any constraints
 *
 *   then cD' = D1, u'::tP[cPsi, x1:B1, ... xn:tBn], [|t|]D2
 *   where  [| lam x1 ... xn. u'[id(cPsi), x1 ... xn] / u |] = t
 *
 *   Effect: u is instantiated to lam x1 ... xn.u'[id(cPsi), x1 ... xn]
 *           if n = 0, u = u' and no effect occurs.
 *
 * FIXME MVar spine is not elaborated consistently with lowering
 *   -- Tue Dec 16 00:19:06 EST 2008
 *)
and lowerMVar = function
  | Inst (_n, _r, _, MTyp(tA,_cPsi), { contents = [] }, mdep) as u ->
      lowerMVar1 u (tA, LF.id)

  | _ ->
      (* It is not clear if it can happen that cnstr =/= nil *)
      (* 2011/01/14: Changed this to a violation for now, to avoid a cyclic dependency on Reconstruct. -mb *)
      raise (Error.Violation "Constraints left")


(*************************************)

let m_id = MShift 0

(* mvar_dot1 psihat t = t'
   Invariant:

   If  cO ;  cD |- t : D'

   then t' = u. (mshift t 1)
       and  for all A s.t.  D' ; Psi |- A : type

              D, u::[|t|](A[Psi]) |- t' : D', A[Psi]
 *)
let rec mvar_dot1 t =
(*    MDot (MV 1, mshift t 1) *)
  MDot (MV 1, mcomp t (MShift 1))

  and pvar_dot1 t =
    MDot (MV 1, mcomp t (MShift 1))


  (* mvar_dot t cD = t'

     if cD1 |- t <= cD2
     then cD1, cD |- t <= cD2, cD
  *)
  and mvar_dot t cD = match cD with
    | Empty -> t
    | Dec(cD', _ ) ->
        mvar_dot (mvar_dot1 t) cD'



(* mcomp t1 t2 = t'

   Invariant:

   If   D'  |- t1 : D
   and  D'' |- t2 : D'
   then t'  =  t1 o t2
   and  D'' |- t1 o t2 : D

   Note: Eagerly composes the modal substitutions t1 and t2.

*)

and mcomp t1 t2 = match (t1, t2) with
  | (MShift 0, t)         -> t
  | (t, MShift 0)         -> t
  | (MShift n, MShift k) -> (MShift (n+k))
  |  (MShift n, MDot (_mft, t))  ->
      mcomp (MShift (n-1)) t
  | (MDot (mft, t), t') ->
      MDot (mfrontMSub mft t', mcomp t t')


(* mfrontMSub Ft t = Ft'

   Invariant:

   If   D |- t : D'     D' ; Psi |- Ft <= A
   then Ft' =  [|t|] Ft
   and  D ; [|t|]Psi |- Ft' : [|t|]A
*)
and mfrontMSub ft t = match ft with
  | MObj (phat, tM)     ->
      let phat = cnorm_psihat phat t in
        MObj (phat, cnorm(tM, t))
  | SObj (phat, tM)     ->
      let phat = cnorm_psihat phat t in
        SObj (phat, cnormSub(tM, t))
  | PObj (phat, h) ->
    let phat = cnorm_psihat phat t in
    PObj (phat, cnormHead (h, t))
  | CObj (cPsi) -> CObj (cnormDCtx (cPsi, t))

  | MV k -> LF.applyMSub k t

(* m_invert t = t'

   Invariant:

   If   D  |- t  <= D'    (and s !!!patsub!!!)
   then D' |- t' <= D
   s.t. t o t' = id    (mcomp t' t = id)
*)
and m_invert s =
  let rec lookup n s p = match s with
    | MShift _                 -> None
    | MDot (MUndef, t')    -> lookup (n + 1) t' p

    | MDot (MV k, t') ->
        if k = p then Some n
        else lookup (n + 1) t' p

    | MDot (CObj(CtxVar (CtxOffset k)), t') ->
        if k = p then
          Some n
        else lookup (n + 1) t' p

    | MDot (MObj(_phat, Root(_, MVar (Offset k, Shift 0), Nil)), t') ->
        if k = p then
          Some n
        else lookup (n + 1) t' p

    | MDot (PObj (_phat, PVar (k, Shift 0)), t') ->
        if k = p then
          Some n
        else lookup (n + 1) t' p


  in

  let rec invert'' p ti = match p with
      | 0 -> ti
      | p ->
          let front = match lookup 1 s p with
            | Some k -> MV k (* or MObj (phat, Root(MVar(Offset k), id), Nil)  *)
            | None   -> MUndef
          in
            invert'' (p - 1) (MDot (front, ti)) in

    let rec invert' n t = match t with
      | MShift p     -> invert'' p (MShift n)
      | MDot (_, t') -> invert' (n + 1) t'

    in
      invert' 0 s


(* Normalization = applying simultaneous hereditary substitution
 *
 * Applying the substitution ss to an LF term tM yields again
 * a normal term. This corresponds to normalizing the term [s]tM.
 *
 * We assume that the LF term tM does not contain any closures
 * MClo (tN,t), TMClo(tA, t), SMClo(tS, t); this means we must
 * first call contextual normalization and then call ordinary
 * normalization.
 *)
(*
 * norm (tM,s) = [s]tM
 *
 * Invariant:
 * if cD ; cPsi  |- tM <= tA
 *    cD ; cPsi' |- s <= cPsi
 * then
 *    cD ; cPsi' |- [s]tM <= [s]tA
 *
 * Similar invariants for norm, normSpine.
 *)
and norm (tM, sigma) = match tM with
  | Lam (loc, y, tN) ->
      Lam (loc, y, norm (tN, LF.dot1 sigma))

  | Tuple (loc, tuple) ->
      Tuple (loc, normTuple (tuple, sigma))

  | Clo (tN, s) ->
      norm (tN, LF.comp s sigma)
  | LFHole _ -> tM
  | Root (loc, h, tS) ->
    begin match normHead (h,sigma) with
      | Head h' -> Root(loc, h', normSpine (tS, sigma))
      | Obj tM -> reduce (tM, LF.id) (normSpine (tS, sigma))
    end 


and normHead (h, sigma) = match h with
  | BVar k -> LF.bvarSub k sigma
  | Const c -> Head (Const c)
  | PVar (p, s) -> Head (PVar (p, normSub' (s, sigma)))
  | AnnH (h, t) -> normHead (h, sigma)
  | Proj (h, i) -> reduceTupleFt(normHead (h, sigma), i)
  | FVar n -> Head (FVar n)
  | FMVar (n,s) -> Head (FMVar (n, normSub' (s, sigma)))
  | FPVar (n,s) -> Head (FPVar (n, normSub' (s, sigma)))
  | HClo (k,sv,r) -> Head (HClo (k, sv, normSub' (r,sigma)))
  | HMClo (k, mm, (mt,s)) -> (* TODO: This is kind of repetitive...*)
    begin match normMMVar (mm,mt) with
      | ResMM (mm',mt') -> Head (HMClo(k,mm',(mt',normSub' (s,sigma))))
      | Result (ISub r) -> normFt' (normFt' (LF.bvarSub k r, s), sigma)
    end 
  | MMVar (mm, (mt,s)) ->
    begin match normMMVar (mm,mt) with
    (* The order in which we normalize mm, n, s, and sigma seems to matter..*)
      | ResMM (mm',mt') -> Head (MMVar (mm', (mt',normSub' (s,sigma))))
      | Result (INorm n) -> Obj (norm (norm (n,s),sigma))
    end 
  | MPVar (mm, (mt,s)) ->
    begin match normMMVar (mm,mt) with
      | ResMM (mm',mt') -> Head (MPVar (mm', (mt',normSub' (s,sigma))))
      | Result (IHead h) -> normFt' (normHead (h,s),sigma)
      | Result (INorm n) -> Obj (norm (norm (n,s), sigma))
    end 
  | MVar (Offset u, s) -> Head (MVar(Offset u, normSub' (s,sigma)))
  | MVar (Inst mm, s) ->
    begin match normMMVar (mm,MShift 0) with
      | ResMM (mm',_) -> Head (MVar (Inst mm', normSub' (s,sigma)))
      | Result (INorm n) -> Obj (norm (norm (n,s),sigma))
    end 

and normMMVar ((n,r,cD,ityp,cnstr,d), t) = match !r with
  | None -> ResMM ((n,r,cD,normITyp ityp,cnstr,d), t)
  | Some tM -> Result (cnormITerm (tM,t))

and normITyp = function
  | MTyp (tA,cPsi) -> MTyp(normTyp(tA, LF.id), cPsi)
  | PTyp (tA,cPsi) -> PTyp(normTyp(tA, LF.id),cPsi)
  | STyp (cPhi, cPsi) -> STyp(cPhi,cPsi)

and normFt' (ft,s) = match ft with
  | Head h -> normHead (h,s)
  | Obj tM -> Obj (norm (tM, s))

and cnormITerm (tM,mt) = match tM with
  | INorm n -> INorm (cnorm (n,mt))
  | IHead h -> IHead (cnormHead (h,mt))
  | ISub s -> ISub (cnormSub (s,mt))    

and reduceTupleFt (ft, i) = match ft with
  | Head h -> Head (Proj (h, i))
  | Obj (Tuple (_loc,tM)) -> Obj (reduceTuple (tM, i))

and reduceTuple = function
  | (Last tM, 1) -> tM
  | (Cons (tM, _rest), 1) -> tM
  | (Cons (_, rest), k) -> reduceTuple (rest, k-1)

and normSub' (r,sigma) = normSub (LF.comp r sigma) (* this is slightly weird *)

and normTuple (tuple, t) = match tuple with
  | Last tM -> Last (norm (tM, t))
  | Cons (tM, rest) ->
      let tM' = norm (tM, t) in
      let rest' = normTuple (rest, t) in
        Cons (tM', rest')

and normSpine (tS, sigma) =
   begin match tS with
     | Nil           -> Nil
     | App  (tN, tS) ->
         let tN' =  norm (tN, sigma) in
         App (tN', normSpine (tS, sigma))
     | SClo (tS, s)  -> normSpine (tS, LF.comp s sigma)
   end

(*  reduce(sM, tS) = M'
 *
 *  cPsi | tS > tA' <= tP
 *  cPsi |  s  : cPsi''      cPsi'' |- tM <= tA''       [s]tA'' = tA'
 *)
and reduce sM spine = reduce' (norm sM, spine)

and reduce' = function
  | (LFHole l, _) -> raise (InvalidLFHole l)
  | (Root (loc,h,sp), spine) -> Root (loc, h, appendSpine (sp,spine))
  | (Lam (loc,n,tM'), App(tN, tS)) -> reduce (tM', Dot(Obj tN, LF.id)) tS
  | (Lam (loc,n,tM'), Nil) -> Lam (loc, n, tM')
  | (Clo sM, tS) -> reduce sM tS
  
and appendSpine = function
  | (Nil,s) -> s
  | (App (tN, tS), s) -> App (tN, appendSpine (tS, s))

and normSub s = match s with
  | EmptySub -> EmptySub
  | Undefs -> Undefs
  | Shift _      -> s
  | Dot (ft, s') -> Dot(normFt ft, normSub s')
  | FSVar ( s , n, sigma) -> FSVar (s, n, normSub sigma)
  | SVar (offset, n, s') -> SVar (offset, n, normSub s')
  | MSVar ((_n, {contents = Some (ISub s)}, _cD0, STyp(_cPsi, _cPhi), _cnstrs, mDep),
    n, (mt, s')) ->
      let s0 = cnormSub (LF.comp (normSub s) (normSub s'), mt) in
      LF.comp (Shift n) s0

  | MSVar (sigma, n, (mt,s')) ->
      MSVar (sigma, n, (mt, normSub s'))

and normFt ft = match ft with
  | Obj tM -> etaContract(norm (tM, LF.id))
  | Head h -> normHead (h, LF.id)



(* normType (tA, sigma) = tA'
 *
 * If cD ; G |- tA <= type
 *    cD ; G' |- sigma <= G
 * then
 *    tA' = [sigma]tA
 *    cD ; G' |- tA' <= type   and tA' is in normal form
 *)
and normTyp (tA, sigma) =  match tA with
  | Atom (loc, a, tS) ->
      Atom (loc, a, normSpine (tS, sigma))

  | PiTyp ((TypDecl (_x, _tA) as decl, dep ), tB) ->
      PiTyp ((normDecl (decl, sigma), dep), normTyp (tB, LF.dot1 sigma))

  | TClo (tA, s) ->
      normTyp (tA, LF.comp s sigma)

  | Sigma recA ->
      Sigma (normTypRec (recA, sigma))

and normTypRec (recA, sigma) = match recA with
  | SigmaLast (n, lastA) ->
      let tA = normTyp (lastA, sigma) in
      SigmaLast(n,tA)

  | SigmaElem (x, tA, recA') ->
      let tA = normTyp (tA, sigma) in
        SigmaElem(x, tA, normTypRec (recA', LF.dot1 sigma))

and normDecl (decl, sigma) = match decl with
  | TypDecl (x, tA) ->
      TypDecl (x, normTyp (tA, sigma))

  | _ -> decl

(* ********************************************************************* *)
(* Normalization = applying simultaneous modal substitution

     Applying the modal substitution t to a normal LF term tM
     yields a normal term. This corresponds to normalizing the term [|t|]tM.
*)

  (*
     cnorm (tM,t) = [|t|]tM

     Invariant:
     if cD ; cPsi  |- tM <= tA
     cD'  |- t <= cD
     then
     [|t|] cPsi = cPsi' , [|t|]tA = tA', [|t|]tM = tM'
     cD' ; cPsi' |- tM' <= tA'

     Similar invariants for cnorm, cnormSpine.

     If tM is in cnormal form, then [|t|]tM is also in cnormal form.

  *)

and cnorm_psihat (phat: psi_hat) t = match phat with
  | (None , _ ) -> phat
  | (Some (CInst ((_n, ({contents = None} as cvar_ref), cD, schema, cnstr,dep), theta)),  k) ->
      (Some (CInst ((_n, cvar_ref, cD, schema, cnstr, dep), mcomp theta t)), k)
  | (Some (CInst ((_n, {contents = Some (ICtx cPsi)}, _cD, _schema, _cnstr, _dep), theta)),  k) ->
      begin match Context.dctxToHat (cnormDCtx (cPsi, mcomp theta t))  with
        | (None, i) -> (None, k+i) (* cnorm_psihat (None, k+i) t *)
        | (Some cvar', i) -> (Some cvar', i+k) (* cnorm_psihat (Some cvar', i+k) t *)
      end
  | (Some (CtxOffset offset), k) ->
      begin match LF.applyMSub offset t with
        | CObj(cPsi) ->
            begin match Context.dctxToHat (cPsi) with
              | (None, i) -> (None, k+i)
              | (Some cvar', i) -> (Some cvar', i+k)
            end
        | MV offset' -> (Some (CtxOffset offset'), k)
      end
  |  _ -> phat

and cnormHead' (h, t) = match h with
  | BVar k -> Head (BVar k)
  | Const c -> Head (Const c)
  | AnnH (h,_) -> cnormHead' (h,t)
  | Proj (h, k) -> reduceTupleFt (cnormHead' (h, t), k)
  | FVar x -> Head (FVar x)
  | FMVar (n,s) -> Head (FMVar (n,cnormSub (s,t)))
  | FPVar (n,s) -> Head (FPVar (n,cnormSub (s,t)))
  | MVar (Offset k, s) -> 
    let s' = cnormSub (s,t) in
    begin match LF.applyMSub k t with
      | MV k' -> Head (MVar(Offset k', s'))
      | MObj (_,tM) -> Obj (norm (tM, s'))
    end	
  | PVar (k, s) ->
    let s' = cnormSub (s,t) in
    begin match LF.applyMSub k t with
      | MV k' -> Head (PVar(k', s'))
      | PObj (_,h) -> normHead (h, s')
      | MObj (_,tM) -> Obj (norm (tM, s'))
    end
  | HClo (k,sv,s) ->
    let s' = cnormSub (s,t) in
    begin match LF.applyMSub sv t with
      | MV sv' -> Head (HClo(k,sv',s'))
      | SObj (_,r) -> normFt' (LF.bvarSub k r, s')
    end
  | MMVar (mm,(mt,s)) ->
    begin match normMMVar (mm,mt) with
      | ResMM (mm',mt) -> Head (MMVar(mm', (cnormMSub' (mt,t), cnormSub (s, t))))
      | Result (INorm n) -> Obj (cnorm(norm(n,s),t))
    end 
  | MPVar (mm,(mt,s)) ->
    begin match normMMVar (mm,mt) with
      | ResMM (mm',mt) -> Head (MPVar(mm', (cnormMSub' (mt,t), cnormSub (s,t))))
      | Result (IHead h) -> cnormFt' (normHead(h,s), t)
      | Result (INorm n) -> Obj (cnorm (norm (n, s), t))
    end 
  | HMClo (k,mm,(mt,s)) ->
    begin match normMMVar (mm,mt) with
      | ResMM (mm',mt) -> Head (HMClo (k, mm', (cnormMSub' (mt,t), cnormSub (s,t))))
      | Result (ISub r) -> cnormFt' (normFt' (LF.bvarSub k r, s), t)
    end 
  | MVar (Inst mm, s) -> 
    begin match normMMVar (mm,MShift 0) with
      | ResMM (mm',_) -> Head (MVar (Inst mm', cnormSub(s,t)))
      | Result (INorm n) -> Obj (norm (n,s))
    end 

and cnormMSub' (mt,t) = cnormMSub (mcomp mt t)
and cnormFt' = function
  | (Head h, t) -> cnormHead' (h,t)
  | (Obj tM, t) -> Obj (cnorm (tM, t))

and cnorm (tM, t) = match tM with
    | Lam (loc, y, tN)   -> Lam (loc, y, cnorm (tN, t))

    | Tuple (loc, tuple) -> Tuple (loc, cnormTuple (tuple, t))

    | Clo (tN, s)        -> Clo(cnorm (tN, t), cnormSub(s, t))

    | LFHole _loc -> LFHole _loc
    
    | Root (loc, head, tS) ->
      begin match cnormHead' (head, t) with
	| Head h' -> Root(loc, h', cnormSpine (tS, t))
	| Obj tM -> reduce (tM, LF.id) (cnormSpine (tS, t))
      end 

(* cnormHead (h,t) = h'
   requires that h is a head such as bound variable or parameter variable associated with pattern sub
   or projection of the previous two
 *)
  and cnormHead (h, t) = match cnormHead' (h,t) with
    | Head h' -> h'

  and cnormSpine (tS, t) = match tS with
    | Nil            -> Nil
    | App  (tN, tS)  -> App (cnorm (tN, t), cnormSpine (tS, t))
    | SClo (tS, s)   -> SClo(cnormSpine (tS, t), cnormSub (s, t))

  and cnormTuple (tuple, t) = match tuple with
    | Last tM -> Last (cnorm (tM, t))
    | Cons (tM, rest) ->
        let tM' = cnorm (tM, t) in
        let rest' = cnormTuple (rest, t) in
          Cons (tM', rest')

  and cnormSub (s, t) = match s with
    | EmptySub -> EmptySub
    | Undefs -> Undefs
    | Shift k -> s
    | Dot (ft, s')    -> Dot (cnormFront (ft, t), cnormSub (s', t))
    | SVar (offset, n, s') ->
      begin match LF.applyMSub offset t with
        | MV offset' -> SVar (offset', n, cnormSub (s', t))
        | SObj (_phat, r) ->
              LF.comp (LF.comp (Shift n) r) (cnormSub (s',t))
      end

    | FSVar (s_name, n, s') ->
        FSVar (s_name, n, cnormSub (s', t))

    | MSVar ((_n, {contents = Some (ISub s)}, _cD0, STyp(_cPsi, _cPhi), _cnstrs, _),
             n, (mt,s')) ->
        let _ = dprint (fun () -> "[cnormSub] MSVar - MSInst") in
        let s0 = cnormSub (LF.comp (normSub s) (normSub s') , mt) in
        let s0' = LF.comp (Shift n) s0 in
          cnormSub (s0', t)

    | MSVar (s ,
             (* s = MSInst (_n, {contents = None}, _cD0, _cPhi, _cPsi, _cnstrs) *)
             n, (mt,s')) ->
          MSVar (s, n, (cnormMSub (mcomp mt t), s'))

  and cnormFront = function
    | Head h , t -> cnormHead' (h, t) 
    | Obj tM , t -> Obj (cnorm (tM , t))
    | Undef , t -> Undef


  (* cnormTyp (tA, t) = tA'

     If cD' ; cPsi  |- tA <= type
     cD |- t <= cD'
     then
     tA' = [|t|]tA  and cPsi' = [|t|]cPsi
     cD' ; cPsi' |- tA' <= type
  *)
  and cnormTyp (tA, t) = match tA with
    | Atom (loc, a, tS) ->
        Atom (loc, a, cnormSpine (tS, t))

    | PiTyp ((TypDecl (_x, _tA) as decl, dep), tB)
      -> PiTyp ((cnormDecl (decl, t), dep), cnormTyp (tB, t))

    | TClo (tA, s)
      -> TClo(cnormTyp (tA,t), cnormSub (s,t))

    | Sigma recA
      -> Sigma(cnormTypRec (recA, t))

  and cnormTypRec (typRec, t) = match typRec with
    |  SigmaLast (n,lastA) -> SigmaLast(n, cnormTyp (lastA, t))
    |  SigmaElem (x, tA, recA') ->
         let tA = cnormTyp (tA, t) in
           SigmaElem (x, tA, cnormTypRec (recA', t))

  and cnormDecl (decl, t) = match decl with
    | TypDecl (x, tA) ->
        TypDecl (x, cnormTyp (tA, t))
    | TypDeclOpt x -> TypDeclOpt x

  (* cnormDCtx (cPsi, t) = cPsi

   If cO ; cD  |- cPsi lf-dctx
      cO ; cD' |-  t_d <= cO ; cD
   then
      cO  ; cD' |- [|t|]cPsi

  *)
  and cnormDCtx (cPsi, t) = match cPsi with
    | Null       ->  Null

    | CtxVar (CInst ((_n, ({contents = None} as cvar_ref), mctx, schema, cnstr, dep), theta )) ->
        CtxVar (CInst ((_n, cvar_ref , mctx, schema , cnstr, dep), mcomp theta t))

    | CtxVar (CInst ((_n, {contents = Some (ICtx cPhi)} ,_mctx, _schema, cnstr, dep), theta)) ->
        cnormDCtx (cPhi, mcomp theta t)

    | CtxVar (CtxOffset psi) ->
        begin match LF.applyMSub psi t with
          | CObj (cPsi') -> normDCtx cPsi'
          | MV k -> CtxVar (CtxOffset k)
        end


    | CtxVar (CtxName psi) -> CtxVar (CtxName psi)


    | DDec(cPsi, decl) ->
        DDec(cnormDCtx(cPsi, t), cnormDecl(decl, t))
and cnormMTyp (mtyp, t) = match mtyp with
    | MTyp (tA, cPsi) ->
        let tA'   = normTyp (cnormTyp(tA, t), LF.id) in
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
          MTyp (tA', cPsi')
    | PTyp (tA, cPsi) ->
        let tA'   = normTyp (cnormTyp(tA, t), LF.id) in
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
          PTyp (tA', cPsi')
    | STyp (cPhi, cPsi) ->
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
        let cPhi' = normDCtx (cnormDCtx(cPhi, t)) in
          STyp (cPhi', cPsi')
    | CTyp sW -> CTyp sW

and cnormMSub t = match t with
  | MShift _n -> t
  | MDot (MObj(phat, tM), t) ->
      MDot (MObj (cnorm_psihat phat m_id,
                  norm (cnorm (tM, m_id), LF.id)) , cnormMSub t)
  | MDot (SObj(phat, s), t) ->
      MDot (SObj(cnorm_psihat phat m_id,
                normSub (cnormSub (s, m_id))), cnormMSub t)
  | MDot (CObj (cPsi), t) ->
        let t' = cnormMSub t in
        let cPsi' = cnormDCtx (normDCtx cPsi, m_id) in
          MDot (CObj cPsi' , t')
  | MDot (PObj(phat, h), t) ->
    MDot (PObj(cnorm_psihat phat m_id, cnormHead (h, m_id)), cnormMSub t)

  | MDot (MV u, t) -> MDot (MV u, cnormMSub t)

  | MDot (MUndef, t) -> MDot (MUndef, cnormMSub t)

(* ************************************************************** *)


and normKind sK = match sK with
  | (Typ, _s) ->
      Typ

  | (PiKind ((decl, dep), tK), s) ->
      PiKind ((normDecl (decl, s), dep), normKind (tK, LF.dot1 s))

and normDCtx cPsi = match cPsi with
  | Null -> Null

  | CtxVar (CInst ((_n, {contents = None} , _mctx, _schema, _cnstr,_dep), _theta )) -> cPsi

  | CtxVar (CInst ((_n, {contents = Some (ICtx cPhi)}, _mctx, _schema, _cnstr,_dep), theta)) ->
      normDCtx (cnormDCtx (cPhi,theta))

  | CtxVar psi -> CtxVar psi

  | DDec (cPsi1, TypDecl (x, Sigma typrec)) ->
      let cPsi1 = normDCtx cPsi1 in
      let typrec = normTypRec (typrec, LF.id) in
        DDec (cPsi1, TypDecl (x, Sigma typrec))

  | DDec (cPsi1, decl) ->
      DDec (normDCtx cPsi1, normDecl (decl, LF.id))

(* ---------------------------------------------------------- *)
(* Weak head normalization = applying simultaneous hereditary
 * substitution lazily
 *
 * Instead of fully applying the substitution sigma to an
 * LF term tM, we apply it incrementally, and delay its application
 * where appropriate using Clo, SClo.
 *
 * We assume that the LF term tM does not contain any closures
 * MClo (tN,t), TMClo(tA, t), SMClo(tS, t); this means we must
 * first call contextual normalization (or whnf) and then call
 * ordinary normalization, if these two substitutions interact.
 *)
(*
 * whnf(tM,s) = (tN,s')
 *
 * Invariant:
 * if cD ; cPsi'  |- tM <= tA
 *    cD ; cPsi   |- s <= cPsi'
 * then
 *    cD ; cPsi  |- s' <= cPsi''
 *    cD ; cPsi''  |- tN  <= tB
 *
 *    cD ; cPsi |- [s]tM = tN[s'] <= tA''
 *    cD ; cPsi |- [s]tA = [s']tB = tA'' <= type
 *
 *  Similar invariants for whnf, whnfTyp.
 *)
and whnf sM = match sM with
  | (Lam _, _s) -> sM

  | (Tuple _, _s) -> sM

  | (Clo (tN, s), s') -> whnf (tN, LF.comp s s')

  | (Root (loc, BVar i, tS), sigma) ->
      begin match LF.bvarSub i sigma with
        | Obj tM        -> whnfRedex ((tM, LF.id), (tS, sigma))
        | Head (BVar k) -> (Root (loc, BVar k, SClo (tS,sigma)), LF.id)
        | Head (Proj(BVar k, j)) -> (Root (loc, Proj(BVar k, j), SClo(tS, sigma)), LF.id)
        | Head head     -> whnf (Root (loc, head, SClo (tS,sigma)), LF.id)
            (* Undef should not happen! *)
      end

  (* Meta^2-variable *)
  | (Root (loc, MPVar ((_, {contents = Some (IHead h)}, _cD, PTyp(_tA,_cPsi), _, _), (t,r)), tS), sigma) ->
      (* constraints associated with q must be in solved form *)
      let h' = cnormHead (h, t) in
        begin match h' with
          | BVar i -> begin match LF.bvarSub i (LF.comp r sigma) with
                        | Obj tM -> whnfRedex ((tM, LF.id), (tS, sigma))
                        | Head (BVar k) -> (Root (loc, BVar k , SClo (tS, sigma)), LF.id)
                        | Head h        -> whnf (Root (loc, h, SClo (tS, sigma)), LF.id)
                        | Undef         -> raise (Error.Violation ("Looking up " ^ string_of_int i ^ "\n"))
                            (* Undef should not happen ! *)
                      end
          | PVar (p, s) -> whnf (Root (loc, PVar (p, LF.comp (LF.comp s r) sigma), SClo (tS, sigma)), LF.id)
          | MPVar (q, (t', r')) -> whnf (Root (loc, MPVar (q, (t', LF.comp r' r)), SClo (tS, sigma)), LF.id)
        end

  | (Root (loc, MPVar ((n, ({contents = None} as pref), cD, PTyp(tA,cPsi), cnstr, mDep), (t,r)), tS), sigma) ->
      (* constraints associated with q must be in solved form *)
      let (cPsi', tA') = (normDCtx cPsi, normTyp (tA, LF.id)) in
      let p' = (n, pref, cD, PTyp(tA',cPsi'), cnstr, mDep) in
        (Root (loc, MPVar (p', (t, LF.comp r sigma)),  SClo(tS, sigma)), LF.id)

  | (Root (_, MMVar ((_, {contents = Some (INorm tM)}, _cD, MTyp(_tA,_cPsi), _, _), (t,r)), tS), sigma) ->
      (* constraints associated with u must be in solved form *)
      let tM' = cnorm (tM, t) in
      let tM'' = norm (tM', r) in
      let sR =  whnfRedex ((tM'', sigma), (tS, sigma)) in

(*      let sR =  whnfRedex ((tM', LF.comp r sigma), (tS, sigma)) in *)
        sR

  | (Root (loc, MMVar ((n, ({contents = None} as uref), cD, MTyp(tA,cPsi), cnstr, mdep), (t, r)), tS), sigma) ->
      (* note: we could split this case based on tA;
       *      this would avoid possibly building closures with id
       *)
      begin match whnfTyp (tA, LF.id) with
        | (Atom (loc', a, tS'), _s (* id *)) ->
            (* meta-variable is of atomic type; tS = Nil  *)
            let u' = (n, uref, cD, MTyp(Atom (loc', a, tS'),cPsi), cnstr, mdep) in
              (Root (loc, MMVar (u', (t, LF.comp r sigma)), SClo (tS, sigma)), LF.id)
        | (PiTyp _, _s)->
            (* Meta-variable is not atomic and tA = Pi x:B1.B2:
             * lower u, and normalize the lowered meta-variable.
             * Note: we may expose and compose substitutions twice.
             *
             * Should be possible to extend it to m^2-variables; D remains unchanged
             * because we never arbitrarily mix pi and pibox.
             *)
            raise (Error.Violation "Meta^2-variable needs to be of atomic type")

      end

  (* Meta-variable *)
  | (Root (loc, MVar (Offset _k as u, r), tS), sigma) ->
      (Root (loc, MVar (u, LF.comp (normSub r) sigma), SClo (tS, sigma)), LF.id)

  | (Root (loc, FMVar (u, r), tS), sigma) ->
      (Root (loc, FMVar (u, LF.comp (normSub r) sigma), SClo (tS, sigma)), LF.id)

  | (Root (_, MVar (Inst (_, {contents = Some (INorm tM)}, _cPsi, _tA, _, _), r), tS), sigma) ->
      (* constraints associated with u must be in solved form *)
      let r' = normSub r in
      let tM' = begin match r' with
                  | Shift 0 -> tM
                  | _ ->   norm(tM, r') (* this can be expensive -bp *)
                end  in
     (* it does not work to call whnfRedex ((tM, LF.comp r sigma), (tS, sigma)) -bp *)
      let sR =  whnfRedex ((tM',  sigma), (tS, sigma)) in
        sR

  | (Root (loc, MVar (Inst (n, ({contents = None} as uref), _cD, MTyp(tA,cPsi), cnstr, mdep) as u, r), tS) as tM, sigma) ->
      (* note: we could split this case based on tA;
       *      this would avoid possibly building closures with id
       *)
      let r' = normSub r in
      begin match whnfTyp (tA, LF.id) with
        | (Atom (loc', a, tS'), _s (* id *)) ->
            (* meta-variable is of atomic type; tS = Nil  *)
            let u' = Inst (n, uref, _cD, MTyp(Atom (loc', a, tS'),cPsi), cnstr, mdep) in
              (Root (loc, MVar (u', LF.comp r' sigma), SClo (tS, sigma)), LF.id)
        | (PiTyp _, _s)->
            (* Meta-variable is not atomic and tA = Pi x:B1.B2:
             * lower u, and normalize the lowered meta-variable.
             * Note: we may expose and compose substitutions twice.
             *)
            let _ = lowerMVar u in
              whnf (tM, sigma)
      end

  (* Parameter variable *)
  | (Root (loc, PVar (p, r), tS), sigma) ->
      (Root (loc, PVar (p, LF.comp (normSub r) sigma), SClo (tS, sigma)), LF.id)

  | (Root (loc, FPVar (p, r), tS), sigma) ->
      (Root (loc, FPVar (p, LF.comp (normSub r) sigma), SClo (tS, sigma)), LF.id)

  | (Root (loc, Proj(FPVar (p, r), k), tS), sigma) ->
      let fpvar = FPVar (p, LF.comp (normSub r) sigma) in
      (Root (loc, Proj(fpvar,k), SClo(tS,sigma)),  LF.id)

  (* Constant *)
  | (Root (loc, Const c, tS), sigma) ->
      (Root (loc, Const c, SClo (tS, sigma)), LF.id)

  (* Projections *)
  | (Root (loc, Proj (BVar i, k), tS), sigma) ->
      begin match LF.bvarSub i sigma with
        | Head (BVar j)      -> (Root (loc, Proj (BVar j, k)     , SClo (tS, sigma)), LF.id)
        | Head (PVar (q, s)) -> (Root (loc, Proj (PVar (q, s), k), SClo (tS, sigma)), LF.id)
      end

  | (Root (loc, Proj (PVar (q, s), k), tS), sigma) ->
      (Root (loc, Proj (PVar (q, LF.comp s sigma), k), SClo (tS, sigma)), LF.id)

  (* Free variables *)
  | (Root (loc, FVar x, tS), sigma) ->
      (Root (loc, FVar x, SClo (tS, sigma)), LF.id)
  | (Root (loc, Proj(MPVar ((_, {contents = Some (IHead h)}, _cD, PTyp(_tA,_cPsi), _, _), (t,r)), k), tS), sigma) ->
      (* constraints associated with q must be in solved form *)
      let h' = cnormHead (h, t) in
        begin match h' with
          | BVar i -> begin match LF.bvarSub i (LF.comp r sigma) with
                        | Head (BVar x) -> (Root (loc, Proj(BVar x,k) , SClo (tS, sigma)), LF.id)
                        | Head h        -> (Root (loc, Proj(h, k), SClo (tS, sigma)), LF.id)
                        | Undef         -> raise (Error.Violation ("Looking up " ^ string_of_int i ^ "\n"))
                            (* Undef should not happen ! *)
                      end
          | PVar (p, s) -> (Root (loc, Proj(PVar (p, LF.comp (LF.comp s r) sigma),k), SClo (tS, sigma)), LF.id)
          | MPVar (q, (t', r')) -> (Root (loc, Proj(MPVar (q, (t', LF.comp (LF.comp r' r) sigma)),k), SClo (tS, sigma)), LF.id)
        end


  | (Root (loc, Proj(MPVar ((n, ({contents = None} as pref), cD, PTyp(tA,cPsi), cnstr, mDep), (t,r)), k), tS), sigma) ->
      (* constraints associated with q must be in solved form *)
      let (cPsi', tA') = (normDCtx cPsi, normTyp (tA, LF.id)) in
      let p' = (n, pref, cD, PTyp(tA', cPsi'), cnstr, mDep) in
        (Root (loc, Proj(MPVar (p', (t, LF.comp r sigma)) , k), SClo(tS, sigma)), LF.id)

  | (Root (_, Proj (MPVar _, _), _), _) -> (dprint (fun () -> "oops 3"); exit 3)

  | (LFHole _loc, _s) -> (LFHole _loc, _s)
  | _ -> (dprint (fun () -> "oops 4"); exit 4)

(* whnfRedex((tM,s1), (tS, s2)) = (R,s')
 *
 * If cD ; Psi1 |- tM <= tA       and cD ; cPsi |- s1 <= Psi1
 *    cD ; Psi2 |- tS > tA <= tP  and cD ; cPsi |- s2 <= Psi2
 * then
 *    cD ; cPsi |- s' : cPsi'    and cD ; cPsi' |- R' -> tP'
 *
 *    [s']tP' = [s2]tP and [s']R' = tM[s1] @ tS[s2]
 *)
and whnfRedex (sM, sS) = match (sM, sS) with
  | ((LFHole l, s1), _) -> raise (InvalidLFHole l)
  | ((Root (_, _, _) as root, s1), (Nil, _s2)) ->
      whnf (root, s1)

  | ((Lam (_, _x, tM), s1), (App (tN, tS), s2)) ->
      let tN' = Clo (    tN , s2) in  (* cD ; cPsi |- tN'      <= tA' *)
      let s1' = Dot (Obj tN', s1) in  (* cD ; cPsi |- tN' . s1 <= Psi1, x:tA''
                                         tA'' = [s1]tA' *)
        whnfRedex ((tM, s1'), (tS, s2))

  | (sM, (SClo (tS, s2'), s2)) ->
      whnfRedex (sM, (tS, LF.comp s2' s2))

  | ((Clo (tM, s), s1), sS) ->
      whnfRedex ((tM, LF.comp s s1), sS)

(* and whnfTupleRedex (tup,s) k = reduceTuple (tup, k), s *)

(* whnfTyp (tA, sigma) = tA'
 *
 * If cD ; cPsi  |- tA <= type
 *    cD ; cPsi' |- sigma <= cPsi
 * then
 *    tA' = [sigma]tA
 *    cD ; cPsi' |- tA' <= type   and tA' is in weak head normal form
 *)
and whnfTyp (tA, sigma) = match tA with
  | Atom (loc, a, tS) -> (Atom (loc, a, SClo (tS, sigma)), LF.id)
  | PiTyp (_cD, _tB)  -> (tA, sigma)
  | TClo (tA, s)      -> whnfTyp (tA, LF.comp s sigma)
  | Sigma _typRec      -> (tA, sigma)


(* ----------------------------------------------------------- *)
(* Check whether constraints are solved *)
and constraints_solved cnstr = match cnstr with
  | [] -> true
  | ({contents = Queued} :: cnstrs) ->
      constraints_solved cnstrs
  | ({contents = Eqn (_cD, _phat, tM, tN)} :: cnstrs) ->
      if conv (tM, LF.id) (tN, LF.id) then
        constraints_solved cnstrs
      else
         false
 | ({contents = Eqh (_cD, _phat, h1, h2)} :: cnstrs) ->
      if convHead (h1, LF.id) (h2, LF.id) then
        constraints_solved cnstrs
      else false



(* Conversion :  Convertibility modulo alpha *)
(* convTyp (tA,s1) (tB,s2) = true iff [s1]tA = [s2]tB
 * conv (tM,s1) (tN,s2) = true    iff [s1]tM = [s2]tN
 * convSpine (S1,s1) (S2,s2) = true iff [s1]S1 = [s2]S2
 *
 * convSub s s' = true iff s = s'
 *
 * This is on normal forms -- needs to be on whnf.
 *)
and conv sM1 sN2 = conv' (whnf sM1) (whnf sN2)

and conv' sM sN = match (sM, sN) with
  | ((Lam (_, _, tM1), s1), (Lam (_, _, tM2), s2)) ->
      conv (tM1, LF.dot1 s1) (tM2, LF.dot1 s2)

  | ((Tuple (_, tuple1), s1), (Tuple (_, tuple2), s2)) ->
      convTuple (tuple1, s1) (tuple2, s2)

  | ((Root (_,AnnH (head, _tA), spine1), s1), sN) ->
       conv' (Root (Syntax.Loc.ghost, head, spine1), s1) sN

  | (sM, (Root(_ , AnnH (head, _tA), spine2), s2)) ->
      conv' sM (Root (Syntax.Loc.ghost, head, spine2), s2)

  | ((Root (_, head1, spine1), s1), (Root (_, head2, spine2), s2)) ->
      convHead (head1,s1) (head2, s2) && convSpine (spine1, s1) (spine2, s2)

  | _ -> false

and convTuple (tuple1, s1) (tuple2, s2) = match (tuple1, tuple2) with
  | (Last tM1,  Last tM2) ->
      conv (tM1, s1) (tM2, s2)

  | (Cons (tM1, tuple1),  Cons(tM2, tuple2)) ->
         conv (tM1, s1) (tM2, s2)
      && convTuple (tuple1, s1) (tuple2, s2)

  | _ -> false

and convHead (head1, s1) (head2, s2) =  match (head1, head2) with
  | (BVar k1, BVar k2) ->
      k1 = k2

  | (Const c1, Const c2) ->
      c1 = c2

  | (MMVar ((_n, u, _cD, MTyp(_tA,cPsi), _cnstr, _) , (_t', s')), MMVar ((_, w, _, MTyp(_, _), _ , _), (_t'',s''))) ->
      u == w && convSub (LF.comp s' s1) (LF.comp s'' s2)
        (* && convMSub   -bp *)

  | (MPVar ((_n, u, _cD, PTyp(_tA,_cPsi), _cnstr, _) , (_t', s')), MPVar ((_, w, _, PTyp(_, _), _, _ ), (_t'',s''))) ->
      u == w && convSub (LF.comp s' s1) (LF.comp s'' s2)
        (* && convMSub   -bp *)

  | (PVar (p, s'), PVar (q, s'')) ->
      p = q && convSub (LF.comp s' s1) (LF.comp s'' s2)

  | (FPVar (p, s'), FPVar (q, s'')) ->
      p = q && convSub (LF.comp s' s1) (LF.comp s'' s2)

  | (MVar (Offset u , s'), MVar (Offset w, s'')) ->
      u = w && convSub (LF.comp s' s1) (LF.comp s'' s2)

  | (MVar (Inst(_n, u, _cPsi, _tA, _cnstr, _) , s'), MVar (Inst(_, w, _, _, _ , _), s'')) ->
      u == w && convSub (LF.comp s' s1) (LF.comp s'' s2)

  | (FMVar (u, s'), FMVar (w, s'')) ->
      u = w && convSub (LF.comp s' s1) (LF.comp s'' s2)

  | (Proj (BVar k1, i), Proj (BVar k2, j)) ->
      k1 = k2 && i = j

  | (Proj (PVar (p, s'), i), Proj (PVar (q, s''), j)) ->
      p = q && i = j && convSub (LF.comp s' s1) (LF.comp s'' s2)
   (* additional case: p[x] = x ? -bp*)

  | (FVar x, FVar y) ->
      x = y

  | (_, _) -> (dprint (fun () -> "falls through ") ;
      false)


and convSpine spine1 spine2 = match (spine1, spine2) with
  | ((Nil, _s1), (Nil, _s2)) ->
      true

  | ((App (tM1, spine1), s1), (App (tM2, spine2), s2)) ->
      conv (tM1, s1) (tM2, s2) && convSpine (spine1, s1) (spine2, s2)

  | (spine1, (SClo (tS, s), s')) ->
      convSpine spine1 (tS, LF.comp s s')

  | ((SClo (tS, s), s'), spine2) ->
      convSpine (tS, LF.comp s s') spine2

and convSub subst1 subst2 = match (subst1, subst2) with
  | (EmptySub, _) -> true (* this relies on the assumption that both are the same type... *)
  | (_,EmptySub) -> true
  | (Undefs,_) -> true (* hopefully Undefs only show up with empty domain? *)
  | (_,Undefs) -> true
  | (Shift n, Shift k) -> n = k 
  | (SVar (s1, k, sigma1), SVar (s2, k', sigma2)) ->
     k = k' &&
     s1 = s2 &&
     convSub sigma1 sigma2

  | (Dot (f, s), Dot (f', s')) ->
      convFront f f' && convSub s s'

  | (Shift n, Dot (Head BVar _k, _s')) ->
      convSub (Dot (Head (BVar (n + 1)), Shift (n + 1))) subst2

  | (Dot (Head BVar _k, _s'), Shift n) ->
      convSub subst1 (Dot (Head (BVar (n + 1)), Shift (n + 1)))

  | _ ->
     (dprint (fun () -> "[convSub] unspecified case"); false)

and convFront front1 front2 = match (front1, front2) with
  | (Head (BVar i), Head (BVar k)) ->
      i = k

  | (Head (Const i), Head (Const k)) ->
      i = k

  | (Head (MMVar (u, (_t,s))), Head (MMVar (v, (_t',s')))) ->
      u = v && convSub s s' (* && convMSub ... to be added -bp *)

  | (Head (PVar (q, s)), Head (PVar (p, s'))) ->
      p = q && convSub s s'

  | (Head (FPVar (q, s)), Head (FPVar (p, s'))) ->
      p = q && convSub s s'

  | (Head (MVar (u, s)), Head (MVar (v, s'))) ->
      u = v && convSub s s'

  | (Head (FMVar (u, s)), Head (FMVar (v, s'))) ->
      u = v && convSub s s'

  | (Head (Proj (head, k)), Head (Proj (head', k'))) ->
      k = k' && convFront (Head head) (Head head')

  | (Head (FVar x), Head (FVar y)) ->
      x = y

  | (Obj tM, Obj tN) ->
      conv (tM, LF.id) (tN, LF.id)

  | (Head BVar i, Obj tN) ->
      begin match etaContract (norm (tN, LF.id)) with
        | Head (BVar k) -> i = k
        | _ -> false
      end

  | (Obj tN, Head (BVar i)) ->
      begin match etaContract (norm (tN, LF.id)) with
        | Head (BVar k) -> i = k
        | _ -> false
      end

  | (Undef, Undef) ->
      true

  | (_, _) ->
      false


and convMSub subst1 subst2 = match (subst1, subst2) with
  | (MShift n, MShift  k) ->
      n = k

  | (MDot (f, s), MDot (f', s')) ->
      convMFront f f' && convMSub s s'

  | (MShift n, MDot (MV _k, _s')) ->
      convMSub (MDot (MV (n + 1), MShift (n + 1))) subst2

  | (MDot (MV _k, _s'), MShift n) ->
      convMSub subst1 (MDot (MV (n + 1), MShift (n + 1)))

  | _ ->
      false

and convMFront front1 front2 = match (front1, front2) with
  | (CObj cPsi, CObj cPhi) ->
      convDCtx cPsi cPhi
  | (MObj (_phat, tM), MObj(_, tN)) ->
      conv (tM, LF.id) (tN, LF.id)
  | (PObj (phat, BVar k), PObj (phat', BVar k')) ->
      phat = phat' && k = k'
  | (PObj (phat, PVar(p,s)), PObj (phat', PVar(q, s'))) ->
      phat = phat' && p = q && convSub s s'
  | (_, _) ->
      false


and convTyp' sA sB = match (sA, sB) with
  | ((Atom (_, (a, b), spine1), s1), (Atom (_, (a', b'), spine2), s2)) ->
      if a = a' && b = b' then
           convSpine (spine1, s1) (spine2, s2)
      else false
(*      a1 = a2 && convSpine (spine1, s1) (spine2, s2)*)

  | ((PiTyp ((TypDecl (_, tA1), _ ), tB1), s1), (PiTyp ((TypDecl (_, tA2), _ ), tB2), s2)) ->
      (* G |- A1[s1] = A2[s2] by typing invariant *)
      convTyp (tA1, s1) (tA2, s2) && convTyp (tB1, LF.dot1 s1) (tB2, LF.dot1 s2)

  | ((Sigma typrec1, s1), (Sigma typrec2, s2)) ->
      convTypRec (typrec1, s1) (typrec2, s2)

  | _ ->
      false



and convTyp sA sB = convTyp' (whnfTyp sA) (whnfTyp sB)




(* convTypRec((recA,s), (recB,s'))
 *
 * Given: cD ; Psi1 |- recA <= type   and cD ; Psi2 |- recB  <= type
 *        cD ; cPsi  |- s <= cPsi       and cD ; cPsi  |- s' <= Psi2
 *
 * returns true iff recA and recB are convertible where
 *    cD ; cPsi |- [s]recA = [s']recB <= type
 *)
and convTypRec sArec sBrec = match (sArec, sBrec) with
  | ((SigmaLast(_, lastA), s), (SigmaLast(_, lastB), s')) ->
      convTyp (lastA, s) (lastB, s')

  | ((SigmaElem (_xA, tA, recA), s), (SigmaElem(_xB, tB, recB), s')) ->
      convTyp (tA, s) (tB, s') && convTypRec (recA, LF.dot1 s) (recB, LF.dot1 s')

  | (_, _) -> (* lengths differ *)
      false

(* convDCtx cPsi cPsi' = true iff
 * cD |- cPsi = cPsi'  where cD |- cPsi ctx,  cD |- cPsi' ctx
 *)
and convDCtx cPsi cPsi' = match (cPsi, cPsi') with
  | (Null, Null) ->
      true

  | (CtxVar c1, CtxVar c2) ->
      c1 = c2

  | (DDec (cPsi1, TypDecl (_, tA)), DDec (cPsi2, TypDecl (_, tB))) ->
      convTyp (tA, LF.id) (tB, LF.id) && convDCtx cPsi1 cPsi2

(*  | (SigmaDec (cPsi , SigmaDecl(_, typrec )),
     SigmaDec (cPsi', SigmaDecl(_, typrec'))) ->
      convDCtx cPsi cPsi' && convTypRec (typrec, LF.id) (typrec', LF.id)
*)
  | (_, _) ->
      false


(* convCtx cPsi cPsi' = true iff
 * cD |- cPsi = cPsi'  where cD |- cPsi ctx,  cD |- cPsi' ctx
 *)
let rec convCtx cPsi cPsi' = match (cPsi, cPsi') with
  | (Empty, Empty) ->
      true

  | (Dec (cPsi1, TypDecl (_, tA)), Dec (cPsi2, TypDecl (_, tB))) ->
      convTyp (tA, LF.id) (tB, LF.id) && convCtx cPsi1 cPsi2

  | _ -> false

let rec convPrefixCtx cPsi cPsi' = match (cPsi, cPsi') with
  | (_ , Empty) ->
      true

  | (Dec (cPsi1, TypDecl (_, tA)), Dec (cPsi2, TypDecl (_, tB))) ->
      convTyp (tA, LF.id) (tB, LF.id) && convCtx cPsi1 cPsi2

  | _ -> false


(* convPrefixTypRec((recA,s), (recB,s'))
 *
 * Given: cD ; Psi1 |- recA <= type   and cD ; Psi2 |- recB  <= type
 *        cD ; cPsi  |- s <= cPsi       and cD ; cPsi  |- s' <= Psi2
 *
 * returns true iff recA and recB are convertible where
 *    cD ; cPsi |-   [s']recB is a prefix of [s]recA
 *)
and convPrefixTypRec sArec sBrec = match (sArec, sBrec) with
  | ((SigmaLast (_,lastA), s), (SigmaLast (_,lastB), s')) ->
      convTyp (lastA, s) (lastB, s')

  | ((SigmaElem (_xA, tA, _recA), s), (SigmaLast(_, tB), s')) ->
      convTyp (tA, s) (tB, s')

  | ((SigmaElem (_xA, tA, recA), s), (SigmaElem(_xB, tB, recB), s')) ->
      convTyp (tA, s) (tB, s') && convPrefixTypRec (recA, LF.dot1 s) (recB, LF.dot1 s')

  | (_, _) -> (* lengths differ *)
      false

let prefixSchElem (SchElem(cSome1, typRec1)) (SchElem(cSome2, typRec2)) =
  convPrefixCtx cSome1 cSome2 && convPrefixTypRec (typRec1, LF.id) (typRec2, LF.id)

(* *********************************************************************** *)
(* Contextual substitutions                                                *)
(* Contextual Weak Head Normalization, Contextual Normalization, and
   alpha-conversion for contextual substitutions                           *)

(*************************************)
(* Contextual Explicit Substitutions *)



(* Eagerly composes substitution

   - All meta-variables must be of atomic type P[Psi]
   - Parameter variables may be of type A[Psi]

   - We decided against a constructor MShift n;
     contextual substitutions provide a mapping for different
     kinds of contextual variables and MShift n does not encode
     this information. Hence, it is not clear how to deal with the case
     comp (MShift n) t   (where t =/= MShift m).

      ---??? but there is a constructor Syntax.LF.MShift of int... -jd 2010-08-10

   - We decided to not provide a constructor Id in msub
     (for similar reasons)
*)



(* ************************************************* *)



let mctxLookup cD k = 
 let rec lookup cD k' = 
   match (cD, k') with
    | (Dec (_cD, Decl (u, mtyp,_)), 1)
      -> (u, cnormMTyp (mtyp, MShift k))
     | (Dec (_cD, DeclOpt u), 1)
      -> raise (Error.Violation "Expected declaration to have type")
    | (Dec (cD, _), k') -> lookup cD (k' - 1)
    | (Empty , _ ) -> raise (Error.Violation ("Meta-variable out of bounds -- looking for " ^ string_of_int k ^ "in context"))
 in
 lookup cD k

(* ************************************************* *)

(* Note: If we don't actually handle this particular exception gracefully, then
   there's no need to have these four distinct functions. Inline them and let it throw
   the match exception instead. *)
let mctxMDec cD' k =
 match (mctxLookup cD' k) with
   | (u, MTyp (tA, cPsi)) -> (u, tA, cPsi)
   | _ -> raise (Error.Violation "Expected ordinary meta-variable")

let mctxPDec cD k =
  match (mctxLookup cD k) with
    | (u, PTyp (tA, cPsi)) -> (u, tA, cPsi)
    | _ -> raise (Error.Violation ("Expected parameter variable"))

let mctxSDec cD' k =
  match (mctxLookup cD' k) with
    | (u, STyp (cPhi, cPsi)) -> (u, cPhi, cPsi)
    | _ -> raise (Error.Violation "Expected substitution variable")

let mctxCDec cD k =
  match (mctxLookup cD k) with
    | (u, CTyp sW) -> (u, sW)
    | _ -> raise (Error.Violation ("Expected context variable"))

let mctxMVarPos cD u =
  let rec lookup cD k = match cD with
    | Dec (cD, Decl(v, mtyp,_))    ->
        if v = u then
         (k, cnormMTyp (mtyp, MShift k))
        else
          lookup cD (k+1)
    | Dec (cD, _) -> lookup cD (k+1)
    | Empty  -> raise Fmvar_not_found
  in
   lookup cD 1

  (******************************************
     Contextual weak head normal form for
     computation-level types
   ******************************************)
  let rec normMetaObj mO = match mO with
    | Comp.MetaCtx (loc, cPsi) ->
        Comp.MetaCtx (loc, normDCtx cPsi)
    | Comp.MetaObj (loc, phat, INorm tM) ->
        Comp.MetaObj (loc, cnorm_psihat phat m_id, INorm (norm (tM, LF.id)))
    | Comp.MetaObjAnn (loc, cPsi, INorm tM) ->
        Comp.MetaObjAnn (loc, normDCtx cPsi, INorm (norm (tM, LF.id)))
    | Comp.MetaObj (loc, phat, ISub tM) ->
        Comp.MetaObj (loc, cnorm_psihat phat m_id, ISub (normSub tM))
    | Comp.MetaObjAnn (loc, cPsi, ISub tM) ->
        Comp.MetaObjAnn (loc, normDCtx cPsi, ISub (normSub tM))

    | Comp.MetaObj (loc, phat, IHead _ ) ->    mO

  and normMetaSpine mS = match mS with
    | Comp.MetaNil -> mS
    | Comp.MetaApp (mO, mS) ->
        Comp.MetaApp (normMetaObj mO, normMetaSpine mS)
 
  let normMTyp = function
    | MTyp (tA, cPsi) -> MTyp (normTyp (tA, LF.id), normDCtx cPsi)
    | PTyp (tA, cPsi) -> PTyp (normTyp (tA, LF.id), normDCtx cPsi)
    | STyp (cPhi,cPsi) -> STyp (normDCtx cPhi, normDCtx cPsi)
    | CTyp g -> CTyp g

  let normMetaTyp = function
    | MTyp (tA, cPsi) -> MTyp (normTyp (tA, LF.id), normDCtx cPsi)
    | PTyp (tA, cPsi) -> PTyp (normTyp (tA, LF.id), normDCtx cPsi)
    | STyp (cPhi,cPsi) -> STyp (normDCtx cPhi, normDCtx cPsi)
    | CTyp (g) -> CTyp (g)

  let rec normCTyp tau = match tau with
    | Comp.TypBase (loc, c, mS) ->
        Comp.TypBase (loc, c, normMetaSpine mS)
    | Comp.TypCobase (loc, c, mS) ->
        Comp.TypCobase (loc, c, normMetaSpine mS)
    | Comp.TypBox (loc, mT)
      -> Comp.TypBox(loc, normMetaTyp mT)
    | Comp.TypArr (tT1, tT2)   ->
        Comp.TypArr (normCTyp tT1, normCTyp tT2)

    | Comp.TypCross (tT1, tT2)   ->
        Comp.TypCross (normCTyp tT1, normCTyp tT2)

    | Comp.TypPiBox ((Decl(u, mtyp,dep)), tau)    ->
        Comp.TypPiBox ((Decl (u, normMTyp mtyp,dep)),
                       normCTyp tau)

    | Comp.TypBool -> Comp.TypBool

  let cnormMetaTyp (mC, t) = match mC with
    | MTyp (tA, cPsi) ->
        let tA'   = normTyp (cnormTyp(tA, t), LF.id) in
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
          MTyp (tA', cPsi')
    | PTyp (tA, cPsi) ->
        let tA'   = normTyp (cnormTyp(tA, t), LF.id) in
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
          PTyp (tA', cPsi')
    | STyp (cPhi, cPsi) ->
        let cPhi' = normDCtx (cnormDCtx(cPhi, t)) in
        let cPsi' = normDCtx (cnormDCtx(cPsi, t)) in
          STyp (cPhi', cPsi')
    | mC -> mC

  let rec cnormMetaObj (mO,t) = match mO with
    | Comp.MetaCtx (loc, cPsi) ->
        Comp.MetaCtx (loc, cnormDCtx (cPsi,t))
    | Comp.MetaObj (loc, phat, INorm tM) ->
        Comp.MetaObj (loc, cnorm_psihat phat t, INorm (norm (cnorm (tM, t), LF.id)))
    | Comp.MetaObjAnn (loc, cPsi, INorm tM) ->
        Comp.MetaObjAnn (loc, cnormDCtx (cPsi, t), INorm (norm (cnorm (tM, t), LF.id)))
    | Comp.MetaObj (loc, phat, ISub sigma) ->
        Comp.MetaObj (loc, cnorm_psihat phat t, ISub (normSub (cnormSub (sigma, t))))
    | Comp.MetaObjAnn (loc, cPsi, ISub sigma) ->
        Comp.MetaObjAnn (loc, cnormDCtx (cPsi, t), ISub (normSub (cnormSub (sigma, t))))
    | Comp.MetaObj (loc, phat, IHead h ) ->  Comp.MetaObj (loc, cnorm_psihat phat t, IHead (cnormHead (h, t)))

  and cnormMetaSpine (mS,t) = match mS with
    | Comp.MetaNil -> mS
    | Comp.MetaApp (mO, mS) ->
        Comp.MetaApp (cnormMetaObj (mO,t), cnormMetaSpine (mS,t))
  
  let cnormCDecl (cdecl, t) = match cdecl with
    | Decl(u, mtyp,dep) -> Decl (u, cnormMTyp (mtyp, t),dep)

  let rec cnormCTyp thetaT =
    begin match thetaT with
      | (Comp.TypBase (loc, a, mS), t) ->
          let mS' = cnormMetaSpine (mS, t) in
            Comp.TypBase (loc, a, mS')
      | (Comp.TypCobase (loc, a, mS), t) ->
          let mS' = cnormMetaSpine (mS, t) in
            Comp.TypCobase (loc, a, mS')

      | (Comp.TypBox (loc, cT), t) ->
	 Comp.TypBox (loc, cnormMetaTyp (cT, t))

      | (Comp.TypArr (tT1, tT2), t)   ->
          Comp.TypArr (cnormCTyp (tT1, t), cnormCTyp (tT2, t))

      | (Comp.TypCross (tT1, tT2), t)   ->
          Comp.TypCross (cnormCTyp (tT1, t), cnormCTyp (tT2, t))

      | (Comp.TypPiBox (cdecl, tau), t)    ->
          let cdecl' = cnormCDecl (cdecl, t) in
          Comp.TypPiBox ((cdecl'),
                         cnormCTyp (tau, mvar_dot1 t))

      | (Comp.TypClo (tT, t'), t)        ->
          cnormCTyp (tT, mcomp t' t)

      | (Comp.TypBool, _t) -> Comp.TypBool
    end

  let rec cnormCKind (cK, t) = match cK with
    | Comp.Ctype loc -> Comp.Ctype loc
    | Comp.PiKind (loc, cdecl , cK) ->
        let cdecl' = cnormCDecl (cdecl, t) in
          Comp.PiKind (loc, cdecl', cnormCKind (cK, mvar_dot1 t))

(*
     cD        |- [|t2|]cG2 = [|t1|]cG1 = cG'
     cD ; cG'  |- [|t2|]tT2 = [|t1|]tT2 = tT
  *)


  let rec cwhnfCTyp thetaT = match thetaT with
    | (Comp.TypBase (loc, c, mS) , t) ->
        let mS' = normMetaSpine (cnormMetaSpine (mS, t)) in
          (Comp.TypBase (loc, c, mS'), m_id)
    | (Comp.TypCobase (loc, c, mS) , t) ->
        let mS' = normMetaSpine (cnormMetaSpine (mS, t)) in
          (Comp.TypCobase (loc, c, mS'), m_id)

    | (Comp.TypBox (loc, cT), t)  -> (Comp.TypBox(loc, cnormMetaTyp (cT, t)), m_id) 

    | (Comp.TypArr (_tT1, _tT2), _t)   -> thetaT

    | (Comp.TypCross (_tT1, _tT2), _t)   -> thetaT

    | (Comp.TypPiBox (_, _) , _)       -> thetaT

    | (Comp.TypClo (tT, t'), t)        -> cwhnfCTyp (tT, mcomp t' t)

    | (Comp.TypBool, _t)               -> thetaT




  (* WHNF and Normalization for computation-level terms to be added -bp *)

  (* cnormExp (e, t) = e'

     If cO ; cD  ; cG   |- e <= tau
        cO ; cD' ; cG'  |- [|t|]e <= tau'  where [|t|]cG = cG' and [|t|]tau = tau'
        cO ; cD'        |- t <= cD

     then e' = [|t|]e and cO ; cD' ; cG' |- e' <= tau'

  *)

  let rec cnormExp (e, t) = match (e,t) with
    | (Comp.Syn (loc, i), t) -> Comp.Syn (loc, cnormExp' (i, t))

    | (Comp.Rec (loc, f, e), t) -> Comp.Rec (loc, f, cnormExp (e,t))

    | (Comp.Fun (loc, x, e), t) -> Comp.Fun (loc, x, cnormExp (e,t))

    | (Comp.Cofun (loc, bs), t) ->
        Comp.Cofun (loc, List.map (fun (cps, e) -> (cps, cnormExp (e, t))) bs)

    | (Comp.MLam (loc, u, e), t) -> Comp.MLam (loc, u, cnormExp (e, mvar_dot1  t))

    | (Comp.Pair (loc, e1, e2), t) -> Comp.Pair (loc, cnormExp (e1, t), cnormExp (e2, t))

    | (Comp.LetPair (loc, i, (x, y, e)), t) ->
        Comp.LetPair (loc, cnormExp' (i, t), (x, y, cnormExp (e, t)))

    | (Comp.Let (loc, i, (x, e)), t) -> 
        Comp.Let (loc, cnormExp' (i, t), (x, cnormExp (e, t)))

    | (Comp.Box (loc, cM), t) ->
        Comp.Box (loc, cnormMetaObj (cM,t))

    | (Comp.Case (loc, prag, i, branches), t) ->
        Comp.Case (loc, prag, cnormExp' (i,t),
                   List.map (function b -> cnormBranch (b, t)) branches)

    | (Comp.If (loc, i, e1, e2), t) ->
        Comp.If (loc, cnormExp' (i,t),
                 cnormExp (e1, t), cnormExp (e2, t))

    | (Comp.Hole (loc, f), _) -> Comp.Hole (loc,f)

  and cnormExp' (i, t) = match (i,t) with
    | (Comp.Var _, _ ) -> i
    | (Comp.DataConst _, _ ) -> i
    | (Comp.DataDest _, _ ) -> i
    | (Comp.Const _, _ ) -> i

    | (Comp.Apply (loc, i, e), t) -> Comp.Apply (loc, cnormExp' (i, t), cnormExp (e,t))


    | (Comp.PairVal (loc, i1, i2), t) ->
        Comp.PairVal (loc, cnormExp' (i1,t), cnormExp' (i2, t))

    | (Comp.MApp (loc, i, cM), t) ->
        Comp.MApp (loc, cnormExp' (i, t),  cnormMetaObj (cM, t))

    | (Comp.Ann (e, tau), t') -> Comp.Ann (cnormExp (e, t), cnormCTyp (tau, mcomp t' t))

    | (Comp.Equal (loc, i1, i2), t) ->
        let i1' = cnormExp' (i1, t) in
        let i2' = cnormExp' (i2, t) in
         (Comp.Equal (loc, i1', i2'))

    | (Comp.Boolean b, t) -> Comp.Boolean(b)

  and cnormPattern (pat, t) = match pat with
    | Comp.PatEmpty (loc, cPsi) ->
        Comp.PatEmpty (loc, cnormDCtx (cPsi, t))
    | Comp.PatMetaObj (loc, mO) ->
        Comp.PatMetaObj (loc, cnormMetaObj (mO, t))
    | Comp.PatConst (loc, c, patSpine) ->
        Comp.PatConst (loc, c, cnormPatSpine (patSpine, t))
    | Comp.PatFVar _ -> pat
    | Comp.PatVar _ -> pat
    | Comp.PatPair (loc, pat1, pat2) ->
        Comp.PatPair (loc, cnormPattern (pat1, t),
                      cnormPattern (pat2, t))
    | Comp.PatTrue loc -> pat
    | Comp.PatFalse loc -> pat
    | Comp.PatAnn (loc, pat, tau) ->
        Comp.PatAnn (loc, cnormPattern (pat, t),
                     cnormCTyp (tau, t))

  and cnormPatSpine (patSpine, t) = match patSpine with
    | Comp.PatNil -> Comp.PatNil
    | Comp.PatApp (loc, pat, patSpine) ->
        Comp.PatApp (loc, cnormPattern (pat, t),
                     cnormPatSpine (patSpine, t))


  (* cnormBranch (BranchBox (cO, cD, (psihat, tM, (tA, cPsi)), e), theta, cs) =

     If  cD1 ; cG |- BranchBox (cD, (psihat, tM, (tA, cPsi)), e) <= [|theta|]tau

              cD ; cPsi |- tM <= tA

         cD1            |- theta <= cD1'

         cD1' ; cG' |- BranchBox (cD, (psihat, tM, (tA, cPsi)), e') <= tau'

         cD1', cD ; cG    |- e' <= tau'

         cG = [|theta|]cG'   and    e  = [|theta|]e'

         |cD| = k

         cD1, cD        |- 1 .... k , (theta o ^k) <= cD1', cD

         cD1, cD        |- (theta o ^k) <= cD1

      then

         cD1, cD ; cG   |- [1...k, (theta o ^k)|]e'  <= [|theta o ^k |]tau

  BROKEN

  *)
  and cnormBranch = function
    | (Comp.EmptyBranch (loc, cD, pat, t), theta) ->
         (* THIS IS WRONG. -bp *)
         Comp.EmptyBranch (loc, cD, pat, cnormMSub t)

    | (Comp.Branch (loc, cD, cG, Comp.PatMetaObj (loc', mO), t, e), theta) ->
    (* cD' |- t <= cD    and   FMV(e) = cD' while
       cD' |- theta' <= cD0
       cD0' |- theta <= cD0
     * Hence, no substitution into e at this point -- technically, we
     * need to unify theta' and theta and then create a new cD'' under which the
     * branch makes sense -bp
     *)
        Comp.Branch (loc, cD, cG, Comp.PatMetaObj (loc', normMetaObj mO), cnormMSub t,
                     cnormExp (e, m_id))

 | (Comp.Branch (loc, cD, cG, pat, t, e), theta) ->
     (* THIS IS WRONG. -bp *)
     Comp.Branch (loc, cD, cG, pat,
                  cnormMSub t, cnormExp (e, m_id))


  let cnormMTyp (ctyp, mtt') = match ctyp with
     | CTyp w -> CTyp w
     | MTyp (tA, cPsi) -> MTyp (cnormTyp (tA, mtt'), cnormDCtx (cPsi, mtt'))
     | PTyp (tA, cPsi) -> PTyp (cnormTyp (tA, mtt'), cnormDCtx (cPsi, mtt'))
     | STyp (cPhi, cPsi) -> STyp (cnormDCtx (cPhi, mtt'), cnormDCtx (cPsi, mtt'))

  let rec cwhnfCtx (cG, t) = match cG with
    | Empty  -> Empty
    | Dec(cG, Comp.CTypDecl (x, tau)) -> Dec (cwhnfCtx (cG,t), Comp.CTypDecl (x, Comp.TypClo (tau, t)))


  let rec cnormCtx (cG, t) = match cG with
    | Empty -> Empty
    | Dec(cG, Comp.CTypDecl(x, tau)) ->
        let tdcl = Comp.CTypDecl (x, cnormCTyp (tau, t)) in
        Dec (cnormCtx (cG, t), tdcl)
    | Dec(cG, Comp.CTypDeclOpt x) ->
        Dec (cnormCtx (cG, t), Comp.CTypDeclOpt x)

  let rec normCtx cG = match cG with
    | Empty -> Empty
    | Dec(cG, Comp.CTypDecl (x, tau)) -> Dec (normCtx cG, Comp.CTypDecl(x, normCTyp (cnormCTyp (tau, m_id))))

  let rec normMCtx cD = match cD with
    | Empty -> Empty
    | Dec(cD, Decl (u, mtyp,dep)) -> Dec(normMCtx cD, Decl (u, normMTyp mtyp,dep))


  (* ----------------------------------------------------------- *)
  (* Conversion: Convertibility modulo alpha for
     computation-level types
  *)



  let rec convMetaObj mO mO' = match (mO , mO) with
    | (Comp.MetaCtx (_loc, cPsi) , Comp.MetaCtx (_ , cPsi'))  ->
        convDCtx  cPsi cPsi'
    | (Comp.MetaObj (_, _phat, INorm tM) , Comp.MetaObj (_, _phat', INorm tM')) ->
        conv (tM, LF.id) (tM', LF.id)
    | (Comp.MetaObj (_, _phat, IHead tH) , Comp.MetaObj (_, _phat', IHead tH')) ->
        convHead (tH, LF.id) (tH', LF.id)
    | (Comp.MetaObj (_, _phat, ISub s) , Comp.MetaObj (_, _phat', ISub s')) ->
        convSub s s'
    | _ -> false

  and convMetaSpine mS mS' = match (mS, mS') with
    | (Comp.MetaNil , Comp.MetaNil) -> true
    | (Comp.MetaApp (mO, mS) , Comp.MetaApp (mO', mS')) ->
        convMetaObj mO mO' && convMetaSpine mS mS'

  (* convCTyp (tT1, t1) (tT2, t2) = true iff [|t1|]tT1 = [|t2|]tT2 *)
  
  let convMTyp thetaT1 thetaT2 = match (thetaT1, thetaT2) with
    | (MTyp (tA1, cPsi1)) , (MTyp (tA2, cPsi2)) ->
        convTyp (tA1, LF.id) (tA2, LF.id) && convDCtx cPsi1 cPsi2
    | (STyp (cPhi, cPsi)) , (STyp (cPhi', cPsi')) ->
        convDCtx cPhi cPhi' && convDCtx cPsi cPsi'
    | (PTyp (tA, cPsi)) , (PTyp (tA', cPsi')) ->
        convTyp (tA, LF.id) (tA', LF.id)  && convDCtx cPsi cPsi'
    | (CTyp cid_schema) , (CTyp cid_schema') ->
       cid_schema = cid_schema'

  let convMetaTyp thetaT1 thetaT2 = convMTyp thetaT1 thetaT2

  let rec convCTyp thetaT1 thetaT2 = convCTyp' (cwhnfCTyp thetaT1) (cwhnfCTyp thetaT2)

  and convCTyp' thetaT1 thetaT2 = match (thetaT1, thetaT2) with
    | ((Comp.TypBase (_, c1, mS1), _t1), (Comp.TypBase (_, c2, mS2), _t2)) ->
          if c1 = c2 then
            (* t1 = t2 = id by invariant *)
            convMetaSpine mS1 mS2
          else false

    | ((Comp.TypCobase (_, c1, mS1), _t1), (Comp.TypCobase (_, c2, mS2), _t2)) ->
          if c1 = c2 then
            (* t1 = t2 = id by invariant *)
            convMetaSpine mS1 mS2
          else false

    | ((Comp.TypBox (_, cT1), _t1) , (Comp.TypBox (_, cT2), _t2)) (* t1 = t2 = id *)
      ->
        convMetaTyp cT1 cT2

    | ((Comp.TypArr (tT1, tT2), t), (Comp.TypArr (tT1', tT2'), t'))
      -> (dprint (fun () -> "[convCtyp] arr part 1");
          convCTyp (tT1, t) (tT1', t'))
        &&
          (dprint (fun () -> "[convCtyp] arr part 2");
           convCTyp (tT2, t) (tT2', t'))

    | ((Comp.TypCross (tT1, tT2), t), (Comp.TypCross (tT1', tT2'), t'))
      -> convCTyp (tT1, t) (tT1', t')
        &&
          convCTyp (tT2, t) (tT2', t')

    | ((Comp.TypPiBox ((Decl(_, mtyp1,_)), tT), t), (Comp.TypPiBox ((Decl(_, mtyp2,_)), tT'), t'))
      ->
        (dprint (fun () -> "[convCtyp] PiBox Mdec");
          convMTyp (cnormMTyp (mtyp1, t)) (cnormMTyp (mtyp2, t'))
        &&
         (dprint (fun () -> "[convCtyp] PiBox decl done");
        convCTyp (tT, mvar_dot1 t) (tT', mvar_dot1 t')))

    | ((Comp.TypBool, _t ), (Comp.TypBool, _t')) -> true

    | ( _ , _ ) -> (dprint (fun () -> "[convCtyp] falls through?");false)

and convSchElem (SchElem (cPsi, trec)) (SchElem (cPsi', trec')) =
    convCtx cPsi cPsi'
  &&
    convTypRec (trec, LF.id) (trec', LF.id)


(* ------------------------------------------------------------ *)


(* etaExpandMV cPsi sA s' = tN
 *
 *  cPsi'  |- s'   <= cPsi
 *  cPsi   |- [s]A <= typ
 *
 *  cPsi'  |- tN   <= [s'][s]A
 *)
let rec etaExpandMV cPsi sA n s' =  etaExpandMV' cPsi (whnfTyp sA) n s'
and etaExpandMV' cPsi sA n s' = match sA with
  | (Atom (_, _a, _tS) as tP, s) ->

      let u = newMVar (Some n) (cPsi, TClo(tP,s)) in 
        Root (Syntax.Loc.ghost, MVar (u, s'), Nil)

  | (PiTyp ((TypDecl (x, _tA) as decl, _ ), tB), s) ->
      Lam (Syntax.Loc.ghost, x, etaExpandMV (DDec (cPsi, LF.decSub decl s)) (tB, LF.dot1 s) n (LF.dot1 s'))

(* Coverage.etaExpandMVstr s' cPsi sA *)

(* etaExpandMMV cD cPsi sA s' = tN
 *
 *  cD ; cPsi'  |- s'   <= cPsi
 *  cD ; cPsi   |- [s]A <= typ
 *
 *  cD ; cPsi'  |- tN   <= [s'][s]A
 *)
let rec etaExpandMMV loc cD cPsi sA n s' = etaExpandMMV' loc cD cPsi (whnfTyp sA) n s'

and etaExpandMMV' loc cD cPsi sA n s' = match sA with
  | (Atom (_, _a, _tS) as tP, s) ->
      let u = newMMVar None (cD , cPsi, TClo(tP,s))  in 
        Root (loc, MMVar (u, (m_id, s')), Nil)

  | (PiTyp ((TypDecl (x, _tA) as decl, _ ), tB), s) ->
      Lam (loc, x, etaExpandMMV loc cD (DDec (cPsi, LF.decSub decl s)) (tB, LF.dot1 s) n (LF.dot1 s'))



let rec closed sM = closedW (whnf sM)

and closedW (tM,s) = match  tM with
  | Lam (_ , _x, tM) -> closed (tM, LF.dot1 s)
  | Root (_ , h, tS) ->
      closedHead h &&
      closedSpine (tS,s)

and closedHead h = match h with
  | MMVar ((_, {contents = None}, _, MTyp(_, _), _, _), _) -> false
  | MVar (Inst (_, {contents = None}, _, _, _, _), _) -> false
  | PVar (_, r) ->
      closedSub r
  | MVar (Offset _, r) ->
      closedSub r
  | _ -> true

and closedSpine (tS,s) = match tS with
  | Nil -> true
  | App (tN, tS') -> closed (tN, s) && closedSpine (tS', s)
  | SClo(tS', s')  -> closedSpine (tS', LF.comp s' s)

and closedSub s = match s with
 | EmptySub -> true
 | Undefs -> true
 | SVar (_ , _ , sigma) ->
        closedSub sigma
  | Shift _ -> true
  | Dot (ft, s) -> closedFront ft && closedSub s

and closedFront ft = match ft with
  | Head h -> closedHead h
  | Obj tM -> closed (tM, LF.id)
  | Undef  -> false


let rec closedTyp sA = closedTypW (whnfTyp sA)

and closedTypW (tA,s) = match tA with
  | Atom (_, _a, tS) -> closedSpine (tS, s)
  | PiTyp ((t_dec, _ ), tA) ->
      closedDecl (t_dec, s) &&
      closedTyp (tA, LF.dot1 s)
  | Sigma recA ->  closedTypRec (recA, s)

and closedTypRec (recA, s) = match recA with
  | SigmaLast (_, tA) -> closedTyp (tA,s)
  | SigmaElem (_, tA, recA') ->
      closedTyp (tA, s) &&
      closedTypRec (recA', LF.dot1 s)

and closedDecl (tdecl, s) = match tdecl with
  | TypDecl (_, tA) -> closedTyp (tA, s)
  | _ -> true


let rec closedDCtx cPsi = match cPsi with
  | Null     -> true
  | CtxVar (CInst ((_, {contents = None}, _, _, _, _), _)) -> false
  | CtxVar (CInst ((_, {contents = Some (ICtx cPsi)}, _,_,_,_ ), theta)) ->
     closedDCtx (cnormDCtx (cPsi, theta))
  | CtxVar _ -> true
  | DDec (cPsi' , tdecl) -> closedDCtx cPsi' && closedDecl (tdecl, LF.id)


let rec closedMetaSpine mS = match mS with
  | Comp.MetaNil -> true
  | Comp.MetaApp (mO, mS) ->
      closedMetaObj mO && closedMetaSpine mS

and closedMetaObj mO = match mO with
  | Comp.MetaCtx (_, cPsi) -> closedDCtx cPsi
  | Comp.MetaObj (_, phat, INorm tM) ->
      closedDCtx (Context.hatToDCtx phat) && closed (tM, LF.id)
  | Comp.MetaObj (_, phat, ISub sigma) ->
      closedDCtx (Context.hatToDCtx phat) && closedSub sigma

let closedMetaTyp cT = match cT with 
  | MTyp (tA, cPsi) -> closedTyp (tA, LF.id) && closedDCtx cPsi
  | CTyp _ -> true
  | PTyp (tA, cPsi) -> closedTyp (tA, LF.id) && closedDCtx cPsi
  | STyp (cPhi, cPsi) -> closedDCtx cPhi && closedDCtx cPsi

let rec closedCTyp cT = match cT with
  | Comp.TypBool -> true
  | Comp.TypBase (_, _c, mS) -> closedMetaSpine mS
  | Comp.TypCobase (_, _c, mS) -> closedMetaSpine mS
  | Comp.TypBox (_ , cT)  -> closedMetaTyp cT
  | Comp.TypArr (cT1, cT2) -> closedCTyp cT1 && closedCTyp cT2
  | Comp.TypCross (cT1, cT2) -> closedCTyp cT1 && closedCTyp cT2
  | Comp.TypPiBox (ctyp_decl, cT) ->
      closedCTyp cT && closedCDecl ctyp_decl
  | Comp.TypClo (cT, t) -> closedCTyp(cnormCTyp (cT, t))  (* to be improved Sun Dec 13 11:45:15 2009 -bp *)

and closedCDecl ctyp_decl = match ctyp_decl with
  | Decl(_, MTyp (tA, cPsi), _) -> closedTyp (tA, LF.id) && closedDCtx cPsi
  | Decl(_, PTyp (tA, cPsi), _) -> closedTyp (tA, LF.id) && closedDCtx cPsi
  | Decl(_, STyp (cPhi, cPsi), _) -> closedDCtx cPhi && closedDCtx cPsi
  | _ -> true

let rec closedGCtx cG = match cG with
  | Empty -> true
  | Dec(cG, Comp.CTypDecl(_ , cT)) ->
      closedCTyp cT && closedGCtx cG
  | Dec(cG, Comp.CTypDeclOpt _ ) -> closedGCtx cG
