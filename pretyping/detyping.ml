(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Errors
open Util
open Names
open Term
open Vars
open Context
open Inductiveops
open Environ
open Glob_term
open Glob_ops
open Termops
open Namegen
open Libnames
open Globnames
open Nametab
open Mod_subst
open Misctypes
open Decl_kinds

let dl = Loc.ghost

(** Should we keep details of universes during detyping ? *)
let print_universes = Flags.univ_print

let add_name na b t (nenv, env) = add_name na nenv, push_rel (na, b, t) env

(****************************************************************************)
(* Tools for printing of Cases                                              *)

let encode_inductive r =
  let indsp = global_inductive r in
  let constr_lengths = constructors_nrealargs indsp in
  (indsp,constr_lengths)

(* Parameterization of the translation from constr to ast      *)

(* Tables for Cases printing under a "if" form, a "let" form,  *)

let has_two_constructors lc =
  Int.equal (Array.length lc) 2 (* & lc.(0) = 0 & lc.(1) = 0 *)

let isomorphic_to_tuple lc = Int.equal (Array.length lc) 1

let encode_bool r =
  let (x,lc) = encode_inductive r in
  if not (has_two_constructors lc) then
    user_err_loc (loc_of_reference r,"encode_if",
      str "This type has not exactly two constructors.");
  x

let encode_tuple r =
  let (x,lc) = encode_inductive r in
  if not (isomorphic_to_tuple lc) then
    user_err_loc (loc_of_reference r,"encode_tuple",
      str "This type cannot be seen as a tuple type.");
  x

module PrintingInductiveMake =
  functor (Test : sig
     val encode : reference -> inductive
     val member_message : std_ppcmds -> bool -> std_ppcmds
     val field : string
     val title : string
  end) ->
  struct
    type t = inductive
    let compare = ind_ord
    let encode = Test.encode
    let subst subst obj = subst_ind subst obj
    let printer ind = pr_global_env Id.Set.empty (IndRef ind)
    let key = ["Printing";Test.field]
    let title = Test.title
    let member_message x = Test.member_message (printer x)
    let synchronous = true
  end

module PrintingCasesIf =
  PrintingInductiveMake (struct
    let encode = encode_bool
    let field = "If"
    let title = "Types leading to pretty-printing of Cases using a `if' form:"
    let member_message s b =
      str "Cases on elements of " ++ s ++
      str
	(if b then " are printed using a `if' form"
         else " are not printed using a `if' form")
  end)

module PrintingCasesLet =
  PrintingInductiveMake (struct
    let encode = encode_tuple
    let field = "Let"
    let title =
      "Types leading to a pretty-printing of Cases using a `let' form:"
    let member_message s b =
      str "Cases on elements of " ++ s ++
      str
	(if b then " are printed using a `let' form"
         else " are not printed using a `let' form")
  end)

module PrintingIf  = Goptions.MakeRefTable(PrintingCasesIf)
module PrintingLet = Goptions.MakeRefTable(PrintingCasesLet)

(* Flags.for printing or not wildcard and synthetisable types *)

open Goptions

let wildcard_value = ref true
let force_wildcard () = !wildcard_value

let _ = declare_bool_option
	  { optsync  = true;
            optdepr  = false;
	    optname  = "forced wildcard";
	    optkey   = ["Printing";"Wildcard"];
	    optread  = force_wildcard;
	    optwrite = (:=) wildcard_value }

let synth_type_value = ref true
let synthetize_type () = !synth_type_value

let _ = declare_bool_option
	  { optsync  = true;
            optdepr  = false;
	    optname  = "pattern matching return type synthesizability";
	    optkey   = ["Printing";"Synth"];
	    optread  = synthetize_type;
	    optwrite = (:=) synth_type_value }

let reverse_matching_value = ref true
let reverse_matching () = !reverse_matching_value

let _ = declare_bool_option
	  { optsync  = true;
            optdepr  = false;
	    optname  = "pattern-matching reversibility";
	    optkey   = ["Printing";"Matching"];
	    optread  = reverse_matching;
	    optwrite = (:=) reverse_matching_value }

(* Auxiliary function for MutCase printing *)
(* [computable] tries to tell if the predicate typing the result is inferable*)

let computable p k =
    (* We first remove as many lambda as the arity, then we look
       if it remains a lambda for a dependent elimination. This function
       works for normal eta-expanded term. For non eta-expanded or
       non-normal terms, it may affirm the pred is synthetisable
       because of an undetected ultimate dependent variable in the second
       clause, or else, it may affirms the pred non synthetisable
       because of a non normal term in the fourth clause.
       A solution could be to store, in the MutCase, the eta-expanded
       normal form of pred to decide if it depends on its variables

       Lorsque le pr�dicat est d�pendant de mani�re certaine, on
       ne d�clare pas le pr�dicat synth�tisable (m�me si la
       variable d�pendante ne l'est pas effectivement) parce que
       sinon on perd la r�ciprocit� de la synth�se (qui, lui,
       engendrera un pr�dicat non d�pendant) *)

  let sign,ccl = decompose_lam_assum p in
  Int.equal (rel_context_length sign) (k + 1)
  &&
  noccur_between 1 (k+1) ccl

let lookup_name_as_displayed env t s =
  let rec lookup avoid n c = match kind_of_term c with
    | Prod (name,_,c') ->
	(match compute_displayed_name_in RenamingForGoal avoid name c' with
           | (Name id,avoid') -> if Id.equal id s then Some n else lookup avoid' (n+1) c'
	   | (Anonymous,avoid') -> lookup avoid' (n+1) (pop c'))
    | LetIn (name,_,_,c') ->
	(match compute_displayed_name_in RenamingForGoal avoid name c' with
           | (Name id,avoid') -> if Id.equal id s then Some n else lookup avoid' (n+1) c'
	   | (Anonymous,avoid') -> lookup avoid' (n+1) (pop c'))
    | Cast (c,_,_) -> lookup avoid n c
    | _ -> None
  in lookup (ids_of_named_context (named_context env)) 1 t

let lookup_index_as_renamed env t n =
  let rec lookup n d c = match kind_of_term c with
    | Prod (name,_,c') ->
	  (match compute_displayed_name_in RenamingForGoal [] name c' with
               (Name _,_) -> lookup n (d+1) c'
             | (Anonymous,_) ->
		 if Int.equal n 0 then
		   Some (d-1)
		 else if Int.equal n 1 then
		   Some d
		 else
		   lookup (n-1) (d+1) c')
    | LetIn (name,_,_,c') ->
	  (match compute_displayed_name_in RenamingForGoal [] name c' with
             | (Name _,_) -> lookup n (d+1) c'
             | (Anonymous,_) ->
		 if Int.equal n 0 then
		   Some (d-1)
		 else if Int.equal n 1 then
		   Some d
		 else
		   lookup (n-1) (d+1) c'
	  )
    | Cast (c,_,_) -> lookup n d c
    | _ -> if Int.equal n 0 then Some (d-1) else None
  in lookup n 1 t

(**********************************************************************)
(* Fragile algorithm to reverse pattern-matching compilation          *)

let update_name na ((_,(e,_)),c) =
  match na with
  | Name _ when force_wildcard () && noccurn (List.index Name.equal na e) c ->
      Anonymous
  | _ ->
      na

let rec decomp_branch ndecls nargs nal b (avoid,env as e) c =
  let flag = if b then RenamingForGoal else RenamingForCasesPattern (fst env,c) in
  if Int.equal ndecls 0 then (List.rev nal,(e,c))
  else
    let na,c,f,nargs',body,t =
      match kind_of_term (strip_outer_cast c) with
	| Lambda (na,t,c) -> na,c,compute_displayed_let_name_in,nargs-1,None,t
	| LetIn (na,b,t,c) when ndecls>nargs ->
            na,c,compute_displayed_name_in,nargs,Some b,t
	| LetIn (na,b,t,c) ->
	    Name default_dependent_ident,(applist (lift 1 c, [mkRel 1])),
	    compute_displayed_name_in,nargs-1,Some b,t 
	| _ -> assert false in
    let na',avoid' = f flag avoid na c in
    decomp_branch (ndecls-1) nargs' (na'::nal) b (avoid',add_name na' body t env) c

let rec build_tree na isgoal e ci cl =
  let mkpat n rhs pl = PatCstr(dl,(ci.ci_ind,n+1),pl,update_name na rhs) in
  let cnl = ci.ci_cstr_ndecls in
  let cna = ci.ci_cstr_nargs in
  List.flatten
    (List.init (Array.length cl)
      (fun i -> contract_branch isgoal e (cnl.(i),cna.(i),mkpat i,cl.(i))))

and align_tree nal isgoal (e,c as rhs) = match nal with
  | [] -> [[],rhs]
  | na::nal ->
    match kind_of_term c with
    | Case (ci,p,c,cl) when
        eq_constr c (mkRel (List.index Name.equal na (fst (snd e))))
	&& (* don't contract if p dependent *)
	computable p (ci.ci_pp_info.ind_nargs) ->
	let clauses = build_tree na isgoal e ci cl in
	List.flatten
          (List.map (fun (pat,rhs) ->
	      let lines = align_tree nal isgoal rhs in
	      List.map (fun (hd,rest) -> pat::hd,rest) lines)
	    clauses)
    | _ ->
	let pat = PatVar(dl,update_name na rhs) in
	let mat = align_tree nal isgoal rhs in
	List.map (fun (hd,rest) -> pat::hd,rest) mat

and contract_branch isgoal e (cdn,can,mkpat,b) =
  let nal,rhs = decomp_branch cdn can [] isgoal e b in
  let mat = align_tree nal isgoal rhs in
  List.map (fun (hd,rhs) -> (mkpat rhs hd,rhs)) mat

(**********************************************************************)
(* Transform internal representation of pattern-matching into list of *)
(* clauses                                                            *)

let is_nondep_branch c n =
  try
    let sign,ccl = decompose_lam_n_assum n c in
    noccur_between 1 (rel_context_length sign) ccl
  with e when Errors.noncritical e -> (* Not eta-expanded or not reduced *)
    false

let extract_nondep_branches test c b n =
  let rec strip n r = if Int.equal n 0 then r else
    match r with
      | GLambda (_,_,_,_,t) -> strip (n-1) t
      | GLetIn (_,_,_,t) -> strip (n-1) t
      | _ -> assert false in
  if test c n then Some (strip n b) else None

let it_destRLambda_or_LetIn_names n c =
  let rec aux n nal c =
    if Int.equal n 0 then (List.rev nal,c) else match c with
      | GLambda (_,na,_,_,c) -> aux (n-1) (na::nal) c
      | GLetIn (_,na,_,c) -> aux (n-1) (na::nal) c
      | _ ->
          (* eta-expansion *)
	  let next l =
	    let x = next_ident_away default_dependent_ident l in
	    (* Not efficient but unusual and no function to get free glob_vars *)
(* 	    if occur_glob_constr x c then next (x::l) else x in *)
	    x
	  in
	  let x = next (free_glob_vars c) in
	  let a = GVar (dl,x) in
	  aux (n-1) (Name x :: nal)
            (match c with
              | GApp (loc,p,l) -> GApp (loc,p,l@[a])
              | _ -> (GApp (dl,c,[a])))
  in aux n [] c

let detype_case computable detype detype_eqns testdep avoid data p c bl =
  let (indsp,st,consnargsl,k) = data in
  let synth_type = synthetize_type () in
  let tomatch = detype c in
  let alias, aliastyp, pred=
    if (not !Flags.raw_print) && synth_type && computable && not (Int.equal (Array.length bl) 0)
    then
      Anonymous, None, None
    else
      match Option.map detype p with
        | None -> Anonymous, None, None
        | Some p ->
            let nl,typ = it_destRLambda_or_LetIn_names k p in
	    let n,typ = match typ with
              | GLambda (_,x,_,t,c) -> x, c
	      | _ -> Anonymous, typ in
	    let aliastyp =
	      if List.for_all (Name.equal Anonymous) nl then None
	      else Some (dl,indsp,nl) in
            n, aliastyp, Some typ
  in
  let constructs = Array.init (Array.length bl) (fun i -> (indsp,i+1)) in
  let tag =
    try
      if !Flags.raw_print then
        RegularStyle
      else if st == LetPatternStyle then
	st
      else if PrintingLet.active indsp then
	LetStyle
      else if PrintingIf.active indsp then
	IfStyle
      else
	st
    with Not_found -> st
  in
  match tag, aliastyp with
  | LetStyle, None ->
      let bl' = Array.map detype bl in
      let (nal,d) = it_destRLambda_or_LetIn_names consnargsl.(0) bl'.(0) in
      GLetTuple (dl,nal,(alias,pred),tomatch,d)
  | IfStyle, None ->
      let bl' = Array.map detype bl in
      let nondepbrs =
	Array.map3 (extract_nondep_branches testdep) bl bl' consnargsl in
      if Array.for_all ((!=) None) nondepbrs then
	GIf (dl,tomatch,(alias,pred),
             Option.get nondepbrs.(0),Option.get nondepbrs.(1))
      else
	let eqnl = detype_eqns constructs consnargsl bl in
	GCases (dl,tag,pred,[tomatch,(alias,aliastyp)],eqnl)
  | _ ->
      let eqnl = detype_eqns constructs consnargsl bl in
      GCases (dl,tag,pred,[tomatch,(alias,aliastyp)],eqnl)

let detype_sort = function
  | Prop Null -> GProp
  | Prop Pos -> GSet
  | Type u ->
    GType
      (if !print_universes
       then 
	  let _, map = Universes.global_universe_names () in
	  let pr_level u = 
	    try Nameops.pr_id (Univ.LMap.find u map) with Not_found -> Univ.Level.pr u
	  in 
	    [Pp.string_of_ppcmds (Univ.Universe.pr_with pr_level u)]
       else [])

type binder_kind = BProd | BLambda | BLetIn

(**********************************************************************)
(* Main detyping function                                             *)

let detype_anonymous = ref (fun loc n -> anomaly ~label:"detype" (Pp.str "index to an anonymous variable"))
let set_detype_anonymous f = detype_anonymous := f

let detype_level l =
  GType (Some (Pp.string_of_ppcmds (Univ.Level.pr l)))

let detype_instance l = 
  if Univ.Instance.is_empty l then None
  else Some (List.map detype_level (Array.to_list (Univ.Instance.to_array l)))

let rec detype flags avoid env sigma t =
  match kind_of_term (collapse_appl t) with
    | Rel n ->
      (try match lookup_name_of_rel n (fst env) with
	 | Name id   -> GVar (dl, id)
	 | Anonymous -> !detype_anonymous dl n
       with Not_found ->
	 let s = "_UNBOUND_REL_"^(string_of_int n)
	 in GVar (dl, Id.of_string s))
    | Meta n ->
	(* Meta in constr are not user-parsable and are mapped to Evar *)
        (* using numbers to be unparsable *)
	GEvar (dl, Id.of_string (string_of_int n), [])
    | Var id ->
	(try let _ = Global.lookup_named id in GRef (dl, VarRef id, None)
	 with Not_found -> GVar (dl, id))
    | Sort s -> GSort (dl,detype_sort s)
    | Cast (c1,REVERTcast,c2) when not !Flags.raw_print ->
        detype flags avoid env sigma c1
    | Cast (c1,k,c2) ->
        let d1 = detype flags avoid env sigma c1 in
	let d2 = detype flags avoid env sigma c2 in
    let cast = match k with
    | VMcast -> CastVM d2
    | NATIVEcast -> CastNative d2
    | _ -> CastConv d2
    in
	GCast(dl,d1,cast)
    | Prod (na,ty,c) -> detype_binder flags BProd avoid env sigma na None ty c
    | Lambda (na,ty,c) -> detype_binder flags BLambda avoid env sigma na None ty c
    | LetIn (na,b,ty,c) -> detype_binder flags BLetIn avoid env sigma na (Some b) ty c
    | App (f,args) ->
      let mkapp f' args' = 
 	match f' with
 	| GApp (dl',f',args'') -> 
 	  GApp (dl,f',args''@args')
 	| _ -> GApp (dl,f',args')
      in
	mkapp (detype flags avoid env sigma f)
	  (Array.map_to_list (detype flags avoid env sigma) args)
    | Const (sp,u) -> GRef (dl, ConstRef sp, detype_instance u)
    | Proj (p,c) ->
      if fst flags || !Flags.in_debugger || !Flags.in_toplevel then
	(* lax mode, used by debug printers only *) 
	GApp (dl, GRef (dl, ConstRef p, None), 
	      [detype flags avoid env sigma c])
      else let ty = Retyping.get_type_of (snd env) sigma c in
	   let (ind, args) = Inductive.find_rectype (snd env) ty in
	     GApp (dl, GRef (dl, ConstRef p, None), 
		   List.map (detype flags avoid env sigma) (args @ [c]))
    | Evar (evk,cl) ->
      let id,l =
        try Evd.evar_ident evk sigma,
          Evd.evar_instance_array 
	    (fun id c -> 
	      try let n = List.index Name.equal (Name id) (fst env) in 
		    isRelN n c 
	      with Not_found -> isVarId id c) 
	    (Evd.find sigma evk) cl
        with Not_found -> Id.of_string ("X" ^ string_of_int (Evar.repr evk)), [] in
        GEvar (dl,id,
               List.map (on_snd (detype flags avoid env sigma)) l)
    | Ind (ind_sp,u) ->
	GRef (dl, IndRef ind_sp, detype_instance u)
    | Construct (cstr_sp,u) ->
	GRef (dl, ConstructRef cstr_sp, detype_instance u)
    | Case (ci,p,c,bl) ->
	let comp = computable p (ci.ci_pp_info.ind_nargs) in
	detype_case comp (detype flags avoid env sigma)
	  (detype_eqns flags avoid env sigma ci comp)
	  is_nondep_branch avoid
	  (ci.ci_ind,ci.ci_pp_info.style,
	   ci.ci_cstr_ndecls,ci.ci_pp_info.ind_nargs)
	  (Some p) c bl
    | Fix (nvn,recdef) -> detype_fix flags avoid env sigma nvn recdef
    | CoFix (n,recdef) -> detype_cofix flags avoid env sigma n recdef

and detype_fix flags avoid env sigma (vn,_ as nvn) (names,tys,bodies) =
  let def_avoid, def_env, lfi =
    Array.fold_left2
      (fun (avoid, env, l) na ty ->
	 let id = next_name_away na avoid in
	 (id::avoid, add_name (Name id) None ty env, id::l))
      (avoid, env, []) names tys in
  let n = Array.length tys in
  let v = Array.map3
    (fun c t i -> share_names flags (i+1) [] def_avoid def_env sigma c (lift n t))
    bodies tys vn in
  GRec(dl,GFix (Array.map (fun i -> Some i, GStructRec) (fst nvn), snd nvn),Array.of_list (List.rev lfi),
       Array.map (fun (bl,_,_) -> bl) v,
       Array.map (fun (_,_,ty) -> ty) v,
       Array.map (fun (_,bd,_) -> bd) v)

and detype_cofix flags avoid env sigma n (names,tys,bodies) =
  let def_avoid, def_env, lfi =
    Array.fold_left2
      (fun (avoid, env, l) na ty ->
	 let id = next_name_away na avoid in
	 (id::avoid, add_name (Name id) None ty env, id::l))
      (avoid, env, []) names tys in
  let ntys = Array.length tys in
  let v = Array.map2
    (fun c t -> share_names flags 0 [] def_avoid def_env sigma c (lift ntys t))
    bodies tys in
  GRec(dl,GCoFix n,Array.of_list (List.rev lfi),
       Array.map (fun (bl,_,_) -> bl) v,
       Array.map (fun (_,_,ty) -> ty) v,
       Array.map (fun (_,bd,_) -> bd) v)

and share_names flags n l avoid env sigma c t =
  match kind_of_term c, kind_of_term t with
    (* factorize even when not necessary to have better presentation *)
    | Lambda (na,t,c), Prod (na',t',c') ->
        let na = match (na,na') with
            Name _, _ -> na
          | _, Name _ -> na'
          | _ -> na in
        let t' = detype flags avoid env sigma t in
	let id = next_name_away na avoid in
        let avoid = id::avoid and env = add_name (Name id) None t env in
        share_names flags (n-1) ((Name id,Explicit,None,t')::l) avoid env sigma c c'
    (* May occur for fix built interactively *)
    | LetIn (na,b,t',c), _ when n > 0 ->
        let t'' = detype flags avoid env sigma t' in
        let b' = detype flags avoid env sigma b in
	let id = next_name_away na avoid in
        let avoid = id::avoid and env = add_name (Name id) (Some b) t' env in
        share_names flags n ((Name id,Explicit,Some b',t'')::l) avoid env sigma c (lift 1 t)
    (* Only if built with the f/n notation or w/o let-expansion in types *)
    | _, LetIn (_,b,_,t) when n > 0 ->
	share_names flags n l avoid env sigma c (subst1 b t)
    (* If it is an open proof: we cheat and eta-expand *)
    | _, Prod (na',t',c') when n > 0 ->
        let t'' = detype flags avoid env sigma t' in
	let id = next_name_away na' avoid in
        let avoid = id::avoid and env = add_name (Name id) None t' env in
        let appc = mkApp (lift 1 c,[|mkRel 1|]) in
        share_names flags (n-1) ((Name id,Explicit,None,t'')::l) avoid env sigma appc c'
    (* If built with the f/n notation: we renounce to share names *)
    | _ ->
        if n>0 then msg_warning (strbrk "Detyping.detype: cannot factorize fix enough");
        let c = detype flags avoid env sigma c in
        let t = detype flags avoid env sigma t in
        (List.rev l,c,t)

and detype_eqns flags avoid env sigma ci computable constructs consnargsl bl =
  try
    if !Flags.raw_print || not (reverse_matching ()) then raise Exit;
    let mat = build_tree Anonymous (snd flags) (avoid,env) ci bl in
    List.map (fun (pat,((avoid,env),c)) -> (dl,[],[pat],detype flags avoid env sigma c))
      mat
  with e when Errors.noncritical e ->
    Array.to_list
      (Array.map3 (detype_eqn flags avoid env sigma) constructs consnargsl bl)

and detype_eqn (lax,isgoal as flags) avoid env sigma constr construct_nargs branch =
  let make_pat x avoid env b body ty ids =
    if force_wildcard () && noccurn 1 b then
      PatVar (dl,Anonymous),avoid,(add_name Anonymous body ty env),ids
    else
      let flag = if isgoal then RenamingForGoal else RenamingForCasesPattern (fst env,b) in
      let na,avoid' = compute_displayed_name_in flag avoid x b in
      PatVar (dl,na),avoid',(add_name na body ty env),add_vname ids na
  in
  let rec buildrec ids patlist avoid env n b =
    if Int.equal n 0 then
      (dl, Id.Set.elements ids,
       [PatCstr(dl, constr, List.rev patlist,Anonymous)],
       detype flags avoid env sigma b)
    else
      match kind_of_term b with
	| Lambda (x,t,b) ->
	    let pat,new_avoid,new_env,new_ids = make_pat x avoid env b None t ids in
            buildrec new_ids (pat::patlist) new_avoid new_env (n-1) b

	| LetIn (x,b,t,b') ->
	    let pat,new_avoid,new_env,new_ids = make_pat x avoid env b' (Some b) t ids in
            buildrec new_ids (pat::patlist) new_avoid new_env (n-1) b'

	| Cast (c,_,_) ->    (* Oui, il y a parfois des cast *)
	    buildrec ids patlist avoid env n c

	| _ -> (* eta-expansion : n'arrivera plus lorsque tous les
                  termes seront construits � partir de la syntaxe Cases *)
            (* nommage de la nouvelle variable *)
	    let new_b = applist (lift 1 b, [mkRel 1]) in
            let pat,new_avoid,new_env,new_ids =
	      make_pat Anonymous avoid env new_b None mkProp ids in
	    buildrec new_ids (pat::patlist) new_avoid new_env (n-1) new_b

  in
  buildrec Id.Set.empty [] avoid env construct_nargs branch

and detype_binder (lax,isgoal as flags) bk avoid env sigma na body ty c =
  let flag = if isgoal then RenamingForGoal else RenamingElsewhereFor (fst env,c) in
  let na',avoid' = match bk with
  | BLetIn -> compute_displayed_let_name_in flag avoid na c
  | _ -> compute_displayed_name_in flag avoid na c in
  let r =  detype flags avoid' (add_name na' body ty env) sigma c in
  match bk with
  | BProd -> GProd (dl, na',Explicit,detype (lax,false) avoid env sigma ty, r)
  | BLambda -> GLambda (dl, na',Explicit,detype (lax,false) avoid env sigma ty, r)
  | BLetIn -> GLetIn (dl, na',detype (lax,false) avoid env sigma (Option.get body), r)

let detype_rel_context ?(lax=false) where avoid env sigma sign =
  let where = Option.map (fun c -> it_mkLambda_or_LetIn c sign) where in
  let rec aux avoid env = function
  | [] -> []
  | (na,b,t)::rest ->
      let na',avoid' =
	match where with
	| None -> na,avoid
	| Some c ->
	    if b != None then
	      compute_displayed_let_name_in
                (RenamingElsewhereFor (fst env,c)) avoid na c
	    else
	      compute_displayed_name_in
                (RenamingElsewhereFor (fst env,c)) avoid na c in
      let b' = Option.map (detype (lax,false) avoid env sigma) b in
      let t' = detype (lax,false) avoid env sigma t in
      (na',Explicit,b',t') :: aux avoid' (add_name na' b t env) rest
  in aux avoid env (List.rev sign)

let detype_names isgoal avoid nenv env sigma t = 
  detype (false,isgoal) avoid (nenv,env) sigma t
let detype ?(lax=false) isgoal avoid env sigma t =
  detype (lax,isgoal) avoid (names_of_rel_context env, env) sigma t

(**********************************************************************)
(* Module substitution: relies on detyping                            *)

let rec subst_cases_pattern subst pat =
  match pat with
  | PatVar _ -> pat
  | PatCstr (loc,((kn,i),j),cpl,n) ->
      let kn' = subst_mind subst kn
      and cpl' = List.smartmap (subst_cases_pattern subst) cpl in
	if kn' == kn && cpl' == cpl then pat else
	  PatCstr (loc,((kn',i),j),cpl',n)

let (f_subst_genarg, subst_genarg_hook) = Hook.make ()

let rec subst_glob_constr subst raw =
  match raw with
  | GRef (loc,ref,u) ->
      let ref',t = subst_global subst ref in
	if ref' == ref then raw else
         detype false [] (Global.env()) Evd.empty t

  | GVar _ -> raw
  | GEvar _ -> raw
  | GPatVar _ -> raw

  | GApp (loc,r,rl) ->
      let r' = subst_glob_constr subst r
      and rl' = List.smartmap (subst_glob_constr subst) rl in
	if r' == r && rl' == rl then raw else
	  GApp(loc,r',rl')

  | GLambda (loc,n,bk,r1,r2) ->
      let r1' = subst_glob_constr subst r1 and r2' = subst_glob_constr subst r2 in
	if r1' == r1 && r2' == r2 then raw else
	  GLambda (loc,n,bk,r1',r2')

  | GProd (loc,n,bk,r1,r2) ->
      let r1' = subst_glob_constr subst r1 and r2' = subst_glob_constr subst r2 in
	if r1' == r1 && r2' == r2 then raw else
	  GProd (loc,n,bk,r1',r2')

  | GLetIn (loc,n,r1,r2) ->
      let r1' = subst_glob_constr subst r1 and r2' = subst_glob_constr subst r2 in
	if r1' == r1 && r2' == r2 then raw else
	  GLetIn (loc,n,r1',r2')

  | GCases (loc,sty,rtno,rl,branches) ->
      let rtno' = Option.smartmap (subst_glob_constr subst) rtno
      and rl' = List.smartmap (fun (a,x as y) ->
        let a' = subst_glob_constr subst a in
        let (n,topt) = x in
        let topt' = Option.smartmap
          (fun (loc,(sp,i),y as t) ->
            let sp' = subst_mind subst sp in
            if sp == sp' then t else (loc,(sp',i),y)) topt in
        if a == a' && topt == topt' then y else (a',(n,topt'))) rl
      and branches' = List.smartmap
			(fun (loc,idl,cpl,r as branch) ->
			   let cpl' =
			     List.smartmap (subst_cases_pattern subst) cpl
			   and r' = subst_glob_constr subst r in
			     if cpl' == cpl && r' == r then branch else
			       (loc,idl,cpl',r'))
			branches
      in
	if rtno' == rtno && rl' == rl && branches' == branches then raw else
	  GCases (loc,sty,rtno',rl',branches')

  | GLetTuple (loc,nal,(na,po),b,c) ->
      let po' = Option.smartmap (subst_glob_constr subst) po
      and b' = subst_glob_constr subst b
      and c' = subst_glob_constr subst c in
	if po' == po && b' == b && c' == c then raw else
          GLetTuple (loc,nal,(na,po'),b',c')

  | GIf (loc,c,(na,po),b1,b2) ->
      let po' = Option.smartmap (subst_glob_constr subst) po
      and b1' = subst_glob_constr subst b1
      and b2' = subst_glob_constr subst b2
      and c' = subst_glob_constr subst c in
	if c' == c && po' == po && b1' == b1 && b2' == b2 then raw else
          GIf (loc,c',(na,po'),b1',b2')

  | GRec (loc,fix,ida,bl,ra1,ra2) ->
      let ra1' = Array.smartmap (subst_glob_constr subst) ra1
      and ra2' = Array.smartmap (subst_glob_constr subst) ra2 in
      let bl' = Array.smartmap
        (List.smartmap (fun (na,k,obd,ty as dcl) ->
          let ty' = subst_glob_constr subst ty in
          let obd' = Option.smartmap (subst_glob_constr subst) obd in
          if ty'==ty && obd'==obd then dcl else (na,k,obd',ty')))
        bl in
	if ra1' == ra1 && ra2' == ra2 && bl'==bl then raw else
	  GRec (loc,fix,ida,bl',ra1',ra2')

  | GSort _ -> raw

  | GHole (loc, knd, solve) ->
    let nknd = match knd with
    | Evar_kinds.ImplicitArg (ref, i, b) ->
      let nref, _ = subst_global subst ref in
      if nref == ref then knd else Evar_kinds.ImplicitArg (nref, i, b)
    | _ -> knd
    in
    let nsolve = Option.smartmap (Hook.get f_subst_genarg subst) solve in
    if nsolve == solve && nknd == knd then raw
    else GHole (loc, nknd, nsolve)

  | GCast (loc,r1,k) ->
      let r1' = subst_glob_constr subst r1 in
      let k' = Miscops.smartmap_cast_type (subst_glob_constr subst) k in
      if r1' == r1 && k' == k then raw else GCast (loc,r1',k')

(* Utilities to transform kernel cases to simple pattern-matching problem *)

let simple_cases_matrix_of_branches ind brs =
  List.map (fun (i,n,b) ->
      let nal,c = it_destRLambda_or_LetIn_names n b in
      let mkPatVar na = PatVar (Loc.ghost,na) in
      let p = PatCstr (Loc.ghost,(ind,i+1),List.map mkPatVar nal,Anonymous) in
      let map name = try Some (Nameops.out_name name) with Failure _ -> None in
      let ids = List.map_filter map nal in
      (Loc.ghost,ids,[p],c))
    brs

let return_type_of_predicate ind nrealargs_ctxt pred =
  let nal,p = it_destRLambda_or_LetIn_names (nrealargs_ctxt+1) pred in
  (List.hd nal, Some (Loc.ghost, ind, List.tl nal)), Some p
