open InferenceTypes 
open MultiEquation
open Name

(* TODO: Hashtbl? *)
(* TODO: "environnement"? *)
module Glob = Map.Make(struct type t = cname let compare = compare end )
module Globeq = Map.Make(struct type t = cname*variable let compare = compare end)

(** [environnement] contains a map from [tname] to [tname list]:
    the (E') rules *)
let environnement = ref Glob.empty

(** [environnement_equi] contains a map for the (E) rules*)

let environnement_equi = ref Globeq.empty

(** [Unsat] is raised if a canonical constraint C ≡ false. *)
exception Unsat
exception Poney

(** [OverlappingInstances] is raised if two rules of kind (E) overlap. *)
exception OverlappingInstances of tname * variable

(** [MultipleClassDefinitions k] is raised if two rules of kind (I)
    share the same goal. *)
exception MultipleClassDefinitions of tname

(** [UnboundClass k] is raised if the type class [k] occurs in a
    constraint while it is undefined. *)
exception UnboundClass of cname


(** [equivalent [b1;..;bN] k t [(k_1,t_1);...;(k_N,t_N)]] registers
    a rule of the form (E). *)
let equivalent l k t lc = 
  environnement_equi := Globeq.add (k,t) (l,lc) (!environnement_equi) 

(*TODO raise Unsat *)

let unbuilt x = match x.structure with
  | None            -> raise Poney  
  | Some (App(a,b)) -> (a,b)  
  | Some (Var(a))   -> (a,a) (*We can forgot the second*)

let rec from_term_to_crterm x =
  let stru = variable_structure x in 
  match stru with 
  | Some(Var a)-> from_term_to_crterm a 
  | Some(App(a,b))->TTerm(App(from_term_to_crterm a,
                              from_term_to_crterm b))
  | None -> TVariable(x);;(*Check that*)

(** [canonicalize pos pool c] where [c = [(k_1,t_1);...;(k_N,t_N)]]
    decomposes [c] into an equivalent constraint [c' =
    [(k'_1,v_1);...;(k'_M,v_M)]], introducing the variables
    [v_1;...;v_M] in [pool]. It raises [Unsat] if the given constraint
    is equivalent to [false]. *)
(*Canonicalize try to apply rules, to transform the constraint to a constraint
on variables. To apply a (E) rule is equivalent to delete exactly one type constructor.
i.e k_1 t_1 , ... k_n t_n => k (C t) give that for example
k(C sometype) become k_1 sometype , .... k_n sometype. And we recursively try to
destruct sometype, to expand k_i. *)
let canonicalize pos pool k =
  let rec nup final = function
    | [] -> final
    | t::q -> if List.mem t final 
      then nup final q 
      else nup (t::final) q in

  let refine_on_variables constr_on_var =   
    let rec refine_on_one_variable l =
      let l = nup [] l in (*Eliminate duplicates*)
      let rec delete_superclasses final = function
        | [] -> final
        | ((cl,var) :: q) as l -> if List.exists (fun (k,v)-> let super = try Glob.find
                                                                                k
                                                                                (!environnement) with
                                                   _->raise Poney in
                                                   List.mem cl super
                                                 ) l 
          then 
            delete_superclasses final q
          else
            delete_superclasses ((cl,var)::final) q
      in
      delete_superclasses [] l in 
    let rec refine_constraints = function
      | [] -> []   
      | ((k_1,v_1) :: q ) as l-> 
        let (class_on_this_variable,list_recursivecall) = 
          List.partition 
            (fun (k,v) -> v = v_1)  
            l        
        in  
        (refine_on_one_variable class_on_this_variable)
        @(refine_constraints list_recursivecall)
    in
    refine_constraints constr_on_var in
  let expand k =
    let nb_appli = ref 0 in
    let l =  List.map 
        (fun (cn,x) ->
           try 
             let (cstruc,sometype) = unbuilt (UnionFind.find x) in
             incr nb_appli;
             let (v,a) = Globeq.find (cn,cstruc) (!environnement_equi) in
             let term = from_term_to_crterm x in 
             let fresh_vars = List.map (fun _ -> variable Flexible ()) v in
             let fresh_assoc = List.combine v fresh_vars in
             let fresh_term = change_arterm_vars fresh_assoc term
             and fresh_expansion =
               List.map (fun (k', a) -> (k', List.assq a fresh_assoc)) a in
             List.iter (introduce pool) fresh_vars;
             let t = chop pool fresh_term in
             Unifier.unify pos (introduce pool) x t;
             fresh_expansion
           with | Poney -> [(cn,x)]
                | Not_found -> raise(UnboundClass(cn)) (*TODO : good*)
        )
        k in (!nb_appli,l) in
  let rec expand_all k = match expand k with
    | (0,l)->List.flatten l
    | _,l -> expand_all (List.flatten l) in 
  let on_var = expand_all k in
  (*Perhaps it's useless to add variable to pool*)
  refine_on_variables on_var




(** [add_implication k [k_1;...;k_N]] registers a rule of the form
    (E'). *)
let add_implication  k l = 
  (* TODO: Check that classes in l have been bound already.
   * Ensures that the superclass order is acyclic *)
  environnement := Glob.add k l (!environnement) 

(** [entails C1 C2] returns true if the canonical constraint [C1] implies
    the canonical constraint [C2]. *)
let entails c1 c2 =
  (** [w_is_superclass k1 k2] returns true if k1 = k2 (weak order)
   *  or if k1 is a superclass of k2. *)
  let rec w_is_superclass k k' =
    k = k' || List.exists (w_is_superclass k) (Glob.find k' !environnement)
  in
  List.for_all
    (fun (k', v') -> List.exists
        (fun (k, v) ->
           try
             UnionFind.equivalent v v' && w_is_superclass k' k
           with Not_found -> raise (UnboundClass k))
        c1)
    c2

(** [contains k1 k2] *)
let contains k1 k2 =
  let v = variable Rigid () in
  entails [(k2, v)] [(k1, v)]

