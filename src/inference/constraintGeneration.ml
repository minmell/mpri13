(**************************************************************************)
(*  Adaptated from:                                                       *)
(*  Mini, a type inference engine based on constraint solving.            *)
(*  Copyright (C) 2006. François Pottier, Yann Régis-Gianas               *)
(*  and Didier Rémy.                                                      *)
(*                                                                        *)
(*  This program is free software; you can redistribute it and/or modify  *)
(*  it under the terms of the GNU General Public License as published by  *)
(*  the Free Software Foundation; version 2 of the License.               *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  General Public License for more details.                              *)
(*                                                                        *)
(*  You should have received a copy of the GNU General Public License     *)
(*  along with this program; if not, write to the Free Software           *)
(*  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA         *)
(*  02110-1301 USA                                                        *)
(*                                                                        *)
(**************************************************************************)

(** This module implements typing constraint generation. *)

open Positions
open Misc
open KindInferencer
open Constraint
open InferenceTypes
open TypeAlgebra
open MultiEquation
open TypingEnvironment
open InferenceExceptions
open Types
open InternalizeTypes
open Name
open IAST

(** {2 Inference} *)

(** Constraint contexts. *)
type context =
  (crterm, variable) type_constraint -> (crterm, variable) type_constraint

let ctx0 = fun c -> c

let (@@) ctx1 ctx2 = fun c -> ctx1 (ctx2 c)

let fold env f =
  List.fold_left (fun (env, ctx) x ->
      let (env, ctx') = f env x in
      (env, ctx @@ ctx')
    ) (env, ctx0)

(** A fragment denotes the typing information acquired in a match branch.
    [gamma] is the typing environment coming from the binding of pattern
    variables. [vars] are the fresh variables introduced to type the
    pattern. [tconstraint] is the constraint coming from the instantiation
    of the data constructor scheme. *)

type fragment =
  {
    gamma       : (crterm * position) StringMap.t;
    vars        : variable list;
    tconstraint : tconstraint;
  }

(** The [empty_fragment] is used when nothing has been bound. *)
let empty_fragment =
  {
    gamma       = StringMap.empty;
    vars        = [];
    tconstraint = CTrue undefined_position;
  }

(** Joining two fragments is straightforward except that the environments
    must be disjoint (a pattern cannot bound a variable several times). *)
let rec join_fragment pos f1 f2 =
  {
    gamma =
      (try
         StringMap.strict_union f1.gamma f2.gamma
       with StringMap.Strict x -> raise (NonLinearPattern (pos, Name x)));
    vars        = f1.vars @ f2.vars;
    tconstraint = f1.tconstraint ^ f2.tconstraint;
  }

(** [infer_pat_fragment p t] generates a fragment that represents the
    information gained by a success when matching p. *)
and infer_pat_fragment tenv p t =
  let join pos = List.fold_left (join_fragment pos) empty_fragment in
  let rec infpat t = function

    (** Wildcard pattern does not generate any fragment. *)
    | PWildcard pos ->
      empty_fragment

    (** We refer to the algebra to know the type of a primitive. *)
    | PPrimitive (pos, p) ->
      { empty_fragment with
        tconstraint = (t =?= type_of_primitive (as_fun tenv) p) pos
      }

    (** Matching against a variable generates a fresh flexible variable,
        binds it to the [name] and forces the variable to be equal to [t]. *)
    | PVar (pos, Name name) ->
      let v = variable Flexible () in
      {
        gamma       = StringMap.singleton name (TVariable v, pos);
        tconstraint = (TVariable v =?= t) pos;
        vars        = [ v ]
      }

    (** A disjunction forces the bounded variables of the subpatterns to
        be equal. For that purpose, we extract the types of the subpatterns'
        environments and we make them equal. *)
    | POr (pos, ps) ->
      let fps = List.map (infpat t) ps in
      (try
         let rgamma = (List.hd fps).gamma in
         let cs =
           List.fold_left (fun env_eqc fragment ->
               StringMap.mapi
                 (fun k (t', _) ->
                    let (t, c) = StringMap.find k env_eqc in
                    (t, (t =?= t') pos ^ c))
                 fragment.gamma)
             (StringMap.mapi (fun k (t, _) -> (t, CTrue pos)) rgamma)
             fps
         in
         let c = StringMap.fold (fun k (_, c) acu -> c ^ acu) cs (CTrue pos)
         in
         {
           gamma       = rgamma;
           tconstraint = c ^ conj (List.map (fun f -> f.tconstraint) fps);
           vars        = List.flatten (List.map (fun f -> f.vars) fps)
         }
       with Not_found ->
         raise (InvalidDisjunctionPattern pos))

    (** A conjunction pattern does join its subpatterns' fragments. *)
    | PAnd (pos, ps) ->
      join pos (List.map (infpat t) ps)

    (** [PAlias (x, p)] is equivalent to [PAnd (PVar x, p)]. *)
    | PAlias (pos, Name name, p) ->
      let fragment = infpat t p in
      { fragment with
        gamma       = StringMap.strict_add name (t, pos) fragment.gamma;
        tconstraint = (SName name <? t) pos ^ fragment.tconstraint
      }

    (** A type constraint is taken into account by the insertion of a type
        equality between [t] and the annotation. *)
    | PTypeConstraint (pos, p, typ) ->
      let fragment = infpat t p
      and ityp = InternalizeTypes.intern pos tenv typ in
      { fragment with
        tconstraint = (ityp =?= t) pos ^ fragment.tconstraint
      }

    (** Matching against a data constructor generates the fragment that:
        - forces [t] to be the type of the constructed value ;
        - constraints the types of the subpatterns to be equal to the arguments
        of the data constructor. *)
    | PData (pos, (DName x as k), _, ps) ->
      let (alphas, kt) = fresh_datacon_scheme pos tenv k in
      let rt = result_type (as_fun tenv) kt
      and ats = arg_types (as_fun tenv) kt in
      if (List.length ps <> List.length ats) then
        raise (NotEnoughPatternArgts pos)
      else
        let fragment = join pos (List.map2 infpat ats ps) in
        let cinst = (SName x <? kt) pos in
        { fragment with
          tconstraint = cinst ^ fragment.tconstraint ^ (t =?= rt) pos ;
          vars        = alphas @ fragment.vars;
        }

    | _ -> assert false (* Unused name constructors *)
  in
  infpat t p

let header_of_binding pos tenv (name, ty) t =
  let x = match name with
    | Name x -> x
    | _ -> assert false (* Unused name constructors *) in
  (match ty with
   | None -> CTrue pos
   | Some ty ->
     (intern pos tenv ty =?= t) pos),
  StringMap.singleton x (t, pos)

let fresh_record_name =
  let r = ref 0 in
  fun () -> incr r; Name (Printf.sprintf "_record_%d" !r)

(** [intern_data_constructor adt_name env_info dcon_info] returns
    env_info augmented with the data constructor's typing information
    It also checks if its definition is legal. *)
(* Unused [adt_name] *)
let intern_data_constructor _ env_info dcon_info =
  let (tenv, acu, lrqs, let_env) = env_info
  and (pos, DName dname, qs, typ) = dcon_info in
  let rqs, rtenv = fresh_unnamed_rigid_vars pos tenv qs in
  let tenv' = add_type_variables rtenv tenv in
  let ityp = InternalizeTypes.intern pos tenv' typ in
  if not (is_regular_datacon_scheme tenv rqs ityp) then
    raise (InvalidDataConstructorDefinition (pos, DName dname));
  (* Unused *)
  let v = variable ~structure:ityp Flexible () in
  ((add_data_constructor tenv (DName dname)
      (InternalizeTypes.arity typ, rqs, ityp)),
   (DName dname, v) :: acu,
   (rqs @ lrqs),
   StringMap.add dname (ityp, pos) let_env)

let bind_new_tycon pos name tenv kind =
  (* Insert the type constructor into the environment. *)
  let ikind = KindInferencer.intern_kind (as_kind_env tenv) kind
  and ids_def = ref Abstract
  and ivar = variable ~name:name Constant () in
  let c = fun c' ->
    CLet ([Scheme (pos, [ivar], [], [], c', StringMap.empty)],
          CTrue pos)
  in
  (ids_def, add_type_constructor tenv name (ikind, ivar, ids_def), c)

let infer_typedef_single (tenv, c) = function
  | TypeDef (pos', kind, name, DRecordType (ts, rts)) ->
    let ids_def, tenv, c = bind_new_tycon pos' name tenv kind in
    let rqs, rtenv = fresh_unnamed_rigid_vars pos' tenv ts in
    let tenv' = add_type_variables rtenv tenv in
    let tyvs = List.map (fun v -> TyVar (pos', v)) ts in
    let rty =
      InternalizeTypes.intern pos' tenv' (TyApp (pos', name, tyvs))
    in
    let intern_label_type (pos, l, ty) =
      (l, InternalizeTypes.intern pos' tenv' ty)
    in
    ids_def := Product (rqs, rty, List.map intern_label_type rts);
    (tenv, c)

  | TypeDef (pos', kind, name, DAlgebraic ds) ->
    let ids_def, tenv, c = bind_new_tycon pos' name tenv kind in
    let (tenv, ids, rqs, let_env) =
      List.fold_left
        (intern_data_constructor name)
        (tenv, [], [], StringMap.empty)
        ds
    in
    ids_def := Sum ids;
    let c = fun c' ->
      c (CLet ([Scheme (pos', rqs, [], [],
                        CTrue pos',
                        let_env)],
               c'))
    in
    (tenv, c)

  | ExternalType (pos, ts, name, _) ->
    let kind = kind_of_arity (List.length ts) in
    let ikind = KindInferencer.intern_kind (as_kind_env tenv) kind in
    let ivar = variable ~name Constant () in
    let tenv = add_type_constructor tenv name (ikind, ivar, ref Abstract) in
    (tenv,
     fun c ->
       CLet ([Scheme (pos, [ivar], [], [], c, StringMap.empty)], CTrue pos)
    )

let infer_typedef tenv (TypeDefs (pos, tds)) =
  List.fold_left infer_typedef_single (tenv, ctx0) tds

(** [infer_vdef pos tenv (pos, qs, p, e)] returns the constraint
    related to a value definition. *)
let rec infer_vdef pos tenv (ValueDef (pos, qs, ps, b, e)) =
  let x = variable Flexible () in
  let tx = TVariable x in
  let rqs, rtenv = fresh_rigid_vars pos tenv qs in
  let tenv' = add_type_variables rtenv tenv in
  let xs, gs, cs = InternalizeTypes.intern_class_predicates pos tenv' ps in
  let c, h = header_of_binding pos tenv' b tx in
  let flex, fqs = if is_value_form e
    then [ ], x :: xs
    else [x],      xs in
  (flex, Scheme (pos, rqs, fqs,
                 gs, c ^ conj cs ^ infer_expr tenv' e tx,
                 h))

(** [infer_binding tenv b] examines a binding [b], updates the
    typing environment if it binds new types or generates
    constraints if it binds values. *)
and infer_binding tenv b =
  match b with
  | ExternalValue (pos, ts, (n, ty), _) ->
    let x = variable Flexible () in
    let tx = TVariable x in
    let rqs, rtenv = fresh_rigid_vars pos tenv ts in
    let tenv' = add_type_variables rtenv tenv in
    let c, h = header_of_binding pos tenv' (n, Some ty) tx in
    let scheme = Scheme (pos, rqs, [x], [], c, h) in
    fun c -> CLet ([scheme], c)

  | BindValue (pos, vdefs) ->
    let xs, schemes = List.(split (map (infer_vdef pos tenv) vdefs)) in
    fun c -> ex (List.flatten xs) (CLet (schemes, c))

  | BindRecValue (pos, vdefs) ->

    (* The constraint context generated for
       [let rec forall X1 . x1 : T1 = e1
       and forall X2 . x2 = e2] is

       let forall X1 (x1 : T1) in
       let forall [X2] Z2 [
       let x2 : Z2 in [ e2 : Z2 ]
       ] ( x2 : Z2) in (
       forall X1.[ e1 : T1 ] ^
       [...]
       )

       In other words, we first assume that x1 has type scheme
       forall X1.T1.
       Then, we typecheck the recursive definition x2 = e2, making sure
       that the type variable X2 remains rigid, and generalize its type.
       This yields a type scheme for x2, which is then used to check
       that e1 actually has type scheme forall X1.T1.

       In the above example, there are only one explicitly typed and one
       implicitly typed value definitions.

       In the general case, there are multiple explicitly and implicitly
       typed definitions, but the principle remains the same. We generate
       a context of the form

       let schemes1 in

       let forall [rqs2] fqs2 [
       let h2 in c2
       ] h2 in (
       c1 ^
       [...]
       )

    *)

    let schemes1, rqs2, fqs2, ps2, h2, c2, c1 =
      List.fold_left
        (fun
          (schemes1, rqs2, fqs2, ps2, h2, c2, c1)
          (ValueDef (pos, qs, ps, b, e)) ->

          (* Allocate variables for the quantifiers in the list
             [qs], augment the type environment accordingly. *)

          let rvs, rtenv = fresh_rigid_vars pos tenv qs in
          let tenv' = add_type_variables rtenv tenv in

          let xs, gs, xcs = intern_class_predicates pos tenv' ps in

          (* Check whether this is an explicitly or implicitly
             typed definition. *)

          match InternalizeTypes.explicit_or_implicit pos b e with
          | InternalizeTypes.Implicit (Name name, e) ->

            let v = variable Flexible () in
            let t = TVariable v in

            schemes1,
            rvs @ rqs2,
            v :: fqs2 @ xs,
            gs @ ps2,
            StringMap.add name (t, pos) h2,
            conj xcs ^ infer_expr tenv' e t ^ c2,
            c1

          | InternalizeTypes.Explicit (Name name, typ, e) ->

            InternalizeTypes.intern_scheme pos tenv name qs ps typ
            :: schemes1,
            rqs2,
            fqs2,
            ps2,
            h2,
            c2,
            fl rvs ~h:gs (ex xs (
                conj xcs
                ^ infer_expr tenv' e (InternalizeTypes.intern pos tenv' typ)
              ))
            ^ c1

          | _ -> assert false (* Unused name constructors *)

        ) ([], [], [], [], StringMap.empty, CTrue pos, CTrue pos) vdefs in

    fun c -> CLet (schemes1,
                   CLet ([ Scheme (pos, rqs2, fqs2, ps2,
                                   CLet ([ monoscheme h2 ], c2), h2) ],
                         c1 ^ c)
                  )

(** [infer_expr tenv d e t] generates a constraint that guarantees that [e]
    has type [t]. It implements the constraint generation rules for
    expressions. It may use [d] as an equation theory to prove coercion
    correctness. *)
and infer_expr tenv e (t : crterm) =
  match e with

  (** The [exists a. e] construction introduces [a] in the typing
      scope so as to be usable in annotations found in [e]. *)
  | EExists (pos, vs, e) ->
    let (fqs, denv) = fresh_flexible_vars pos tenv vs in
    let tenv = add_type_variables denv tenv in
    ex fqs (infer_expr tenv e t)

  | EForall (pos, vs, e) ->
    (** Not in the implicitly typed language. *)
    assert false

  (** The type of a variable must be at least as general as [t]. *)
  | EVar (pos, Name name, _) ->
    (SName name <? t) pos

  (** To type a lambda abstraction, [t] must be an arrow type.
      Furthermore, type variables introduced by the lambda pattern
      cannot be generalized locally. *)
  | ELambda (pos, b, e) ->
    exists (fun x1 ->
        exists (fun x2 ->
            let (c, h) = header_of_binding pos tenv b x1 in
            c
            ^ CLet ([ monoscheme h ], infer_expr tenv e x2)
            ^ (t =?= arrow tenv x1 x2) pos
          )
      )

  (** Application requires the left hand side to be an arrow and
      the right hand side to be compatible with the domain of this
      arrow. *)
  | EApp (pos, e1, e2) ->
    exists (fun x ->
        infer_expr tenv e1 (arrow tenv x t) ^ infer_expr tenv e2 x
      )

  (** A binding [b] defines a constraint context into which the
      constraint of [e] must be injected. *)
  | EBinding (_, b, e) ->
    infer_binding tenv b (infer_expr tenv e t)

  (** A type constraint inserts a type equality into the generated
      constraint. *)
  | ETypeConstraint (pos, e, typ) ->
    let ityp = intern pos tenv typ in
    (t =?= ityp) pos ^ infer_expr tenv e ityp

  (** The constraint of a [match] makes equal the type of the scrutinee
      and the type of every branch pattern. The body of each branch must
      be equal to [t]. *)
  | EMatch (pos, e, branches) ->
    exists (fun x ->
        infer_expr tenv e x ^
        conj
          (List.map
             (fun (Branch (pos, p, e)) ->
                let fragment = infer_pat_fragment tenv p x in
                CLet ([ Scheme (pos, [], fragment.vars, [],
                                fragment.tconstraint,
                                fragment.gamma) ],
                      infer_expr tenv e t))
             branches))

  (** A data constructor application is similar to usual application
      except that it must be fully applied. *)
  | EDCon (pos, (DName d as k), _, es) ->
    let arity, _, _ = lookup_datacon tenv k in
    let les = List.length es in
    if les <> arity then
      raise (PartialDataConstructorApplication (pos, arity, les))
    else
      exists_list es
        (fun xs ->
           let (kt, c) =
             List.fold_left (fun (kt, c) (e, x) ->
                 arrow tenv x kt, c ^ infer_expr tenv e x)
               (t, CTrue pos)
               (List.rev xs)
           in
           c ^ (SName d <? kt) pos)

  (** We refers to the algebra to get the primitive's type. *)
  | EPrimitive (pos, c) ->
    (t =?= type_of_primitive (as_fun tenv) c) pos

  | ERecordCon (pos, Name k, _, []) ->
    let h = StringMap.add k (t, pos) StringMap.empty in
    CLet ([ monoscheme h ], (SName k <? t) pos)
    ^ infer_expr tenv (EPrimitive (pos, PUnit)) t

  (** The record definition by extension. *)
  | ERecordCon (pos, Name k, i, bindings) ->
    let ci =
      match i with
      | None -> CTrue pos
      | Some ty -> (intern pos tenv ty =?= t) pos
    in
    let h = StringMap.add k (t, pos) StringMap.empty in
    CLet ([ monoscheme h ], (SName k <? t) pos)
    ^ exists_list bindings
      (fun xs ->
         List.(
           let ls = map extract_label_from_binding bindings in
           let (vs, (rty, ltys)) = fresh_product_of_label pos tenv (hd ls) in
           ex vs (
             ci ^ (t =?= rty) pos
             ^ CConjunction (map (infer_label pos tenv ltys) xs)
           )
         )
      )

  (** Accessing the label [label] of [e1] requires [e1]'s type to
      be a record in which [label] is assign a [pre x] type. *)
  | ERecordAccess (pos, e1, label) ->
    exists (fun x ->
        exists (fun y ->
            let (vs, (rty, ltys)) = fresh_product_of_label pos tenv label in
            ex vs (
              infer_expr tenv e1 rty
              ^ (t =?= List.assoc label ltys) pos
            )
          )
      )

  | _ -> assert false (* Unused name constructors *)

and extract_label_from_binding (RecordBinding (name, _)) =
  name

and infer_label pos tenv ltys (RecordBinding (l, exp), t) =
  try
    ((List.assoc l ltys) =?= t) pos ^ infer_expr tenv exp t
  with Not_found ->
    raise (IncompatibleLabel (pos, l))

let infer_class tenv ({ class_position = pos ;
                        class_name     = k   } as c) =
  (* A class definition [class K_1 'a, ..., K_n 'a => K 'a { ... }]
   * introduces an implication K 'a => K_1 'a /\ ... /\ K_n 'a *)
  ConstraintSimplifier.(
    try
      add_implication k c.superclasses;
    with
    | SUnboundClass k -> raise (UnboundClass (pos, k))
    | SMultipleClassDefinitions ->
      raise (MultipleClassDefinitions (pos, k)));

  (* Introduce type variable 'a (class parameter). [rq] is a singleton *)
  let rq, rtenv = fresh_rigid_vars pos tenv [c.class_parameter] in
  let tenv' = add_type_variables rtenv tenv in

  (* Bind methods as values *)
  let bind_method (xs, cs, h) = function
    | pos, MName m, ty ->
      let x = variable Flexible () in
      let tx = TVariable x in
      let c = (intern pos tenv' ty =?= tx) pos in
      (x :: xs, c ^ cs, StringMap.add m (tx, pos) h)
    | _ -> assert false (* Unused name constructors *)
  in

  let scheme = match rq with
    | [q] ->
      let xs, cs, h = List.fold_left
          bind_method ([], CTrue pos, StringMap.empty) c.class_members in
      Scheme (pos, rq, xs, [k, q], cs, h)
    | _ -> assert false (* Only one parameter (see def. of [rq] above) *) in
  add_class tenv c,
  fun c -> CLet ([scheme], c)

let infer_instance tenv ({ instance_position       = pos ;
                           instance_parameters     = ts  ;
                           instance_typing_context = ps  ;
                           instance_class_name     = k   ;
                           instance_index          = i   } as ti) =
  (* An instance definition
   * [instance K_1 'a_1, ..., K_n 'a_n => K ('a_1, ..., 'a_n) cons { ... }]
   * introduces an equivalence
   * K_1 'a_1, ..., K_n 'a_n <=> K ('a_1, ..., 'a_n) cons *)
  ConstraintSimplifier.(
    try
      equivalent ts k i ps;
    with
    | SOverlappingInstances ->
      raise (OverlappingInstances (pos, k, i))
    | SUnboundClass k ->
      raise (UnboundClass (pos, k)));

  (* Introduce type variables *)
  let rs, rtenv = fresh_rigid_vars pos tenv ts in
  let tenv' = add_type_variables rtenv tenv in

  (* Convert class predicates *)
  let ps' =
    List.map
      (fun (ClassPredicate (k, v)) -> k, proj2_3 (List.assoc v rtenv))
      ps in

  (* The type for which an instance is being declared *)
  let itype = Types.cons_type i ts in

  (* Recover methods and their types in which the type variable
   * is substituted with [itype] *)
  let ms = lookup_class pos tenv k itype in

  let infer_method acc (RecordBinding (m, e)) =
    let ty =
      try
        List.assoc m ms
      with Not_found -> raise (UnboundLabel (pos, m))
    in
    let ty' = intern pos tenv' ty in
    acc ^ infer_expr tenv' e ty'
  in

  let scheme = Scheme (pos, rs, [], ps', CTrue pos, StringMap.empty) in

  tenv,
  fun c ->
    let cs = List.fold_left infer_method c ti.instance_members in
    CLet ([scheme], cs)

(** [infer e] determines whether the expression [e] is well-typed
    in the empty environment. *)
let infer tenv e =
  exists (infer_expr tenv e)

(** [bind b] generates a constraint context that describes the
    top-level binding [b]. *)
let bind = infer_binding

let rec infer_program env p =
  let (env, ctx) = fold env block p in
  ctx (CDump undefined_position)

and block env = function
  | BClassDefinition c -> infer_class env c
  | BTypeDefinitions ts -> infer_typedef env ts
  | BInstanceDefinitions is -> fold env infer_instance is
  | BDefinition d -> env, bind env d

let init_env () =
  let builtins =
    init_builtin_env (fun ?name () -> variable Rigid ?name:name ())
  in

  (* Add the builtin data constructors into the environment. *)
  let init_ds adt_name acu ds =
    let (env, acu, lrqs, let_env) as r =
      List.fold_left
        (fun acu (d, rqs, ty) ->
           intern_data_constructor adt_name acu
             (undefined_position, d, rqs, ty)
        ) acu ds
    in
    (acu, r)
  in

  (* For each builtin algebraic datatype, define a type constructor
     and related data constructors into the environment. *)
  let (init_env, acu, lrqs, let_env) =
    List.fold_left
      (fun (env, dvs, lrqs, let_env) (n, (kind, v, ds)) ->
         let r = ref Abstract in
         let env = add_type_constructor env n
             (KindInferencer.intern_kind (as_kind_env env) kind,
              variable ~name:n Constant (),
              r)
         in
         let (dvs, acu) = init_ds n (env, dvs, lrqs, let_env) ds in
         r := Sum dvs;
         acu
      )
      (empty_environment, [], [], StringMap.empty)
      (List.rev builtins)
  in
  let vs =
    fold_type_info (fun vs (n, (_, v, _)) -> v :: vs) [] init_env
  in
  (* The initial environment is implemented as a constraint context. *)
  ((fun c ->
      CLet ([ Scheme (undefined_position, vs, [], [],
                      CLet ([ Scheme (undefined_position, lrqs, [], [],
                                      CTrue undefined_position,
                                      let_env) ],
                            c),
                      StringMap.empty) ],
            CTrue undefined_position)),
   vs, init_env)

let generate_constraint b =
  let (ctx, vs, env) = init_env () in
  (ctx (infer_program env b))
