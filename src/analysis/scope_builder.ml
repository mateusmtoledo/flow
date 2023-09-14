(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Flow_ast_visitor
open Hoister

module Make (L : Loc_sig.S) (Api : Scope_api_sig.S with module L = L) :
  Scope_builder_sig.S with module L = L and module Api = Api = struct
  module L = L
  module Api = Api
  open Api

  class with_or_eval_visitor =
    object (this)
      inherit [bool, L.t] visitor ~init:false as super

      method! expression (expr : (L.t, L.t) Ast.Expression.t) =
        let open Ast.Expression in
        if this#acc = true then
          expr
        else
          match expr with
          | ( _,
              Call
                {
                  Call.callee = (_, Identifier (_, { Ast.Identifier.name = "eval"; comments = _ }));
                  _;
                }
            ) ->
            this#set_acc true;
            expr
          | _ -> super#expression expr

      method! statement (stmt : (L.t, L.t) Ast.Statement.t) =
        if this#acc = true then
          stmt
        else
          super#statement stmt

      method! with_ _loc (stuff : (L.t, L.t) Ast.Statement.With.t) =
        this#set_acc true;
        stuff
    end

  (* Visitor class that prepares use-def info, hoisting bindings one scope at a
     time. This info can be used for various purposes, e.g. variable renaming.

     We do not generate the scope tree for the entire program, because it is not
     clear where to hang scopes for function expressions, catch clauses,
     etc. One possibility is to augment the AST with scope identifiers.

     As we move into a nested scope, we generate bindings for the new scope, map
     the bindings to names generated by a factory, and augment the existing
     environment with this map before visiting the nested scope.
  *)
  module Acc = struct
    type t = info

    let init = { max_distinct = 0; scopes = IMap.empty }
  end

  module Env : sig
    type t

    val empty : t

    val mk_env : (unit -> int) -> t -> L.t Bindings.t -> t

    val get : string -> t -> Def.t option

    val defs : t -> Def.t SMap.t
  end = struct
    type t = Def.t SMap.t list

    let empty = []

    let rec get x t =
      match t with
      | [] -> None
      | hd :: rest -> begin
        match SMap.find_opt x hd with
        | Some def -> Some def
        | None -> get x rest
      end

    let defs = function
      | [] -> SMap.empty
      | hd :: _ -> hd

    let mk_env next parent_env bindings =
      let bindings = Bindings.to_assoc bindings in
      let env =
        List.fold_left
          (fun env (x, (kind, locs)) ->
            let name =
              match get x parent_env with
              | Some def -> def.Def.name
              | None -> next ()
            in
            SMap.add x { Def.locs; name; actual_name = x; kind } env)
          SMap.empty
          bindings
      in
      env :: parent_env
  end

  let remove_params_default =
    let visitor =
      object (_this)
        inherit [unit, L.t] visitor ~init:()

        method! default_opt expr =
          match expr with
          | None -> expr
          | Some _ -> None
      end
    in
    fun params ->
      let params' = visitor#function_params params in
      let has_default = params' != params in
      (has_default, params')

  let pattern_with_toplevel_annot_removed =
    let missing = Ast.Type.Missing L.none in
    fun patt ->
      let open Ast.Pattern in
      match patt with
      | (loc, Identifier ({ Identifier.annot; _ } as id)) ->
        (annot, (loc, Identifier { id with Identifier.annot = missing }))
      | (loc, Object ({ Object.annot; _ } as obj)) ->
        (annot, (loc, Object { obj with Object.annot = missing }))
      | (loc, Array ({ Array.annot; _ } as arr)) ->
        (annot, (loc, Array { arr with Array.annot = missing }))
      | (_, Expression _) -> (missing, patt)

  class component_annot_collector_and_default_remover =
    object (this)
      inherit [(L.t, L.t) Ast.Type.t list, L.t] visitor ~init:[]

      method! type_annotation_hint return =
        let open Ast.Type in
        match return with
        | Available (_, annot) ->
          acc <- annot :: acc;
          Missing L.none
        | Missing _ -> return

      method! component_param param =
        let open Ast.Statement.ComponentDeclaration.Param in
        let (loc, { name; local; default = _; shorthand }) = param in
        let local' = this#component_param_pattern local in
        (loc, { name; local = local'; default = None; shorthand })
    end

  class scope_builder ~flowmin_compatibility ~enable_enums ~with_types =
    object (this)
      inherit [Acc.t, L.t] visitor ~init:Acc.init as super

      val mutable env = Env.empty

      val mutable current_scope_opt = None

      val mutable scope_counter = 0

      val mutable uses = []

      method private new_scope =
        let new_scope = scope_counter in
        scope_counter <- scope_counter + 1;
        new_scope

      val mutable counter = 0

      method in_toplevel_scope =
        Base.List.mem ~equal:( = ) Api.toplevel_scopes (Base.Option.value_exn current_scope_opt)

      method private next =
        let result = counter in
        counter <- counter + 1;
        this#update_acc (fun acc -> { acc with max_distinct = max counter acc.max_distinct });
        result

      method with_bindings : 'a. ?lexical:bool -> L.t -> L.t Bindings.t -> ('a -> 'a) -> 'a -> 'a =
        fun ?(lexical = false) loc bindings visit node ->
          let save_counter = counter in
          let save_uses = uses in
          let old_env = env in
          let parent = current_scope_opt in
          let child = this#new_scope in
          uses <- [];
          current_scope_opt <- Some child;
          env <- Env.mk_env (fun () -> this#next) old_env bindings;
          Exception.protect
            ~f:(fun () -> visit node)
            ~finally:(fun () ->
              this#update_acc (fun acc ->
                  let defs = Env.defs env in
                  let locals =
                    SMap.fold
                      (fun _ def locals ->
                        Nel.fold_left
                          (fun locals loc -> L.LMap.add loc def locals)
                          locals
                          def.Def.locs)
                      defs
                      L.LMap.empty
                  in
                  let (locals, globals) =
                    List.fold_left
                      (fun (locals, globals) (loc, { Ast.Identifier.name = x; comments = _ }) ->
                        match Env.get x env with
                        | Some def -> (L.LMap.add loc def locals, globals)
                        | None -> (locals, SSet.add x globals))
                      (locals, SSet.empty)
                      uses
                  in
                  let scopes =
                    IMap.add child { Scope.lexical; parent; defs; locals; globals; loc } acc.scopes
                  in
                  { acc with scopes }
              );
              uses <- save_uses;
              current_scope_opt <- parent;
              env <- old_env;
              counter <- save_counter)

      method! identifier (expr : (L.t, L.t) Ast.Identifier.t) =
        uses <- expr :: uses;
        expr

      method! jsx_element_name_identifier (id : (L.t, L.t) Ast.JSX.Identifier.t) =
        let open Ast.JSX.Identifier in
        let (loc, { name; comments = _ }) = id in
        uses <- Flow_ast_utils.ident_of_source (loc, name) :: uses;
        id

      method! jsx_element_name_namespaced ns =
        (* TODO: what identifiers does `<foo:bar />` read? *)
        super#jsx_element_name_namespaced ns

      method! type_alias _loc alias =
        if not with_types then
          alias
        else
          let open Ast.Statement.TypeAlias in
          let { id; tparams; right; comments = _ } = alias in
          ignore @@ this#binding_type_identifier id;
          this#scoped_type_params tparams ~in_tparam_scope:(fun () -> ignore @@ this#type_ right);
          alias

      method! opaque_type _loc alias =
        if not with_types then
          alias
        else
          let open Ast.Statement.OpaqueType in
          let { id; tparams; impltype; supertype; comments = _ } = alias in
          ignore @@ this#binding_type_identifier id;
          this#scoped_type_params tparams ~in_tparam_scope:(fun () ->
              ignore @@ Base.Option.map ~f:this#type_ impltype;
              ignore @@ Base.Option.map ~f:this#type_ supertype
          );
          alias

      method! interface _loc interface =
        if not with_types then
          interface
        else
          let open Ast.Statement.Interface in
          let { id; tparams; extends; body = (body_loc, body); comments = _ } = interface in
          ignore @@ this#binding_type_identifier id;
          let extends_targs =
            Base.List.filter_map
              ~f:(fun (_ext_loc, { Ast.Type.Generic.id; targs; comments = _ }) ->
                ignore @@ this#generic_identifier_type id;
                targs)
              extends
          in
          this#scoped_type_params tparams ~in_tparam_scope:(fun () ->
              ignore @@ Base.List.map ~f:this#type_args extends_targs;
              ignore @@ this#object_type body_loc body
          );
          interface

      (* don't rename the `foo` in `x.foo` *)
      method! member_property_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

      (* don't rename the `foo` in `typeof x.foo` *)
      method! typeof_member_identifier ident = ident

      (* don't rename the `ComponentType` in `React.ComponentType` *)
      method! member_type_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

      (* don't rename the `foo` in `const {foo: bar} = x` *)
      method! pattern_object_property_identifier_key ?kind id =
        ignore kind;
        id

      (* don't rename the `Foo` in `enum E { Foo }` *)
      method! enum_member_identifier id = id

      (* don't rename the `foo` in `{ foo: ... }` *)
      method! object_key_identifier (id : (L.t, L.t) Ast.Identifier.t) = id

      (* don't rename the `foo` in `component C(foo: number) {}` *)
      method! component_param_name param_name = param_name

      method! import_declaration loc decl =
        let open Ast.Statement.ImportDeclaration in
        let { import_kind; _ } = decl in
        (* when `with_types` is false, don't visit `import type ...` or `import typeof ...` *)
        match (with_types, import_kind) with
        | (false, ImportType)
        | (false, ImportTypeof) ->
          decl
        | _ -> super#import_declaration loc decl

      (* don't rename the `foo` in `import {foo as bar} from ...;` *)
      method! import_named_specifier
          ~import_kind (specifier : (L.t, L.t) Ast.Statement.ImportDeclaration.named_specifier) =
        let open Ast.Statement.ImportDeclaration in
        (* when `with_types` is false, only visit values, not types. `import_declaration`
           avoids visiting specifiers for `import type` and `import typeof`, so
           `kind = None` must mean a value here. *)
        let visitor kind =
          match (import_kind, kind) with
          | ((ImportType | ImportTypeof), _)
          | (_, Some (ImportType | ImportTypeof)) ->
            if with_types then
              Some this#binding_type_identifier
            else
              None
          | _ -> Some (this#pattern_identifier ~kind:Ast.Variable.Const)
        in
        (match specifier with
        | { local = Some ident; remote = _; remote_name_def_loc = _; kind }
        | { local = None; remote = ident; remote_name_def_loc = _; kind } ->
          let visitor = visitor kind in
          ignore (Base.Option.map ~f:(fun visitor -> visitor ident) visitor));
        specifier

      (* don't rename the `bar` in `export {foo as bar}` *)
      method! export_named_declaration_specifier
          (spec : (L.t, L.t) Ast.Statement.ExportNamedDeclaration.ExportSpecifier.t) =
        let open Ast.Statement.ExportNamedDeclaration.ExportSpecifier in
        let (_, { local; exported = _ }) = spec in
        ignore (this#identifier local);
        spec

      method! block loc (stmt : (L.t, L.t) Ast.Statement.Block.t) =
        let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        let lexical_bindings = lexical_hoist#eval (lexical_hoist#block loc) stmt in
        this#with_bindings ~lexical:true loc lexical_bindings (super#block loc) stmt

      method! function_body (body : 'loc * ('loc, 'loc) Ast.Statement.Block.t) =
        let (loc, block) = body in
        (loc, super#block loc block)

      method! switch loc (switch : ('loc, 'loc) Ast.Statement.Switch.t) =
        let open Ast.Statement.Switch in
        let { discriminant; cases; comments = _; exhaustive_out = _ } = switch in
        let _ = this#expression discriminant in
        let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        let lexical_bindings =
          lexical_hoist#eval
            (Base.List.map ~f:(fun ((_, { Case.consequent; _ }) as case) ->
                 let _ = lexical_hoist#statement_list consequent in
                 case
             )
            )
            cases
        in
        let _ =
          this#with_bindings
            ~lexical:true
            loc
            lexical_bindings
            (this#switch_cases loc discriminant)
            cases
        in
        switch

      method private switch_cases _ _ cases = Base.List.map ~f:this#switch_case cases

      method private scoped_for_in_statement loc (stmt : (L.t, L.t) Ast.Statement.ForIn.t) =
        super#for_in_statement loc stmt

      method! for_in_statement loc (stmt : (L.t, L.t) Ast.Statement.ForIn.t) =
        let open Ast.Statement.ForIn in
        let { left; right = _; body = _; each = _; comments = _ } = stmt in
        let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        let lexical_bindings =
          match left with
          | LeftDeclaration (loc, decl) ->
            lexical_hoist#eval (lexical_hoist#variable_declaration loc) decl
          | LeftPattern _ -> Bindings.empty
        in
        this#with_bindings
          ~lexical:true
          loc
          lexical_bindings
          (this#scoped_for_in_statement loc)
          stmt

      method private scoped_for_of_statement loc (stmt : (L.t, L.t) Ast.Statement.ForOf.t) =
        super#for_of_statement loc stmt

      method! for_of_statement loc (stmt : (L.t, L.t) Ast.Statement.ForOf.t) =
        let open Ast.Statement.ForOf in
        let { left; right = _; body = _; await = _; comments = _ } = stmt in
        let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        let lexical_bindings =
          match left with
          | LeftDeclaration (loc, decl) ->
            lexical_hoist#eval (lexical_hoist#variable_declaration loc) decl
          | LeftPattern _ -> Bindings.empty
        in
        this#with_bindings
          ~lexical:true
          loc
          lexical_bindings
          (this#scoped_for_of_statement loc)
          stmt

      method private scoped_for_statement loc (stmt : (L.t, L.t) Ast.Statement.For.t) =
        super#for_statement loc stmt

      method! for_statement loc (stmt : (L.t, L.t) Ast.Statement.For.t) =
        let open Ast.Statement.For in
        let { init; test = _; update = _; body = _; comments = _ } = stmt in
        let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        let lexical_bindings =
          match init with
          | Some (InitDeclaration (loc, decl)) ->
            lexical_hoist#eval (lexical_hoist#variable_declaration loc) decl
          | _ -> Bindings.empty
        in
        this#with_bindings ~lexical:true loc lexical_bindings (this#scoped_for_statement loc) stmt

      method! catch_clause loc (clause : (L.t, L.t) Ast.Statement.Try.CatchClause.t') =
        let open Ast.Statement.Try.CatchClause in
        let { param; body = _; comments = _ } = clause in
        (* hoisting *)
        let lexical_bindings =
          match param with
          | Some p ->
            let lexical_hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
            lexical_hoist#eval lexical_hoist#catch_clause_pattern p
          | None -> Bindings.empty
        in
        this#with_bindings ~lexical:true loc lexical_bindings (super#catch_clause loc) clause

      (* helper for function params and body *)
      method private lambda
          ~is_arrow:_ ~fun_loc:_ ~generator_return_loc:_ params return predicate body =
        let open Ast.Function in
        let body_loc =
          match body with
          | BodyExpression (loc, _)
          | BodyBlock (loc, _) ->
            loc
        in
        let (has_default_parameters, params_without_defaults) = remove_params_default params in
        if has_default_parameters then begin
          (* We need to create a second scope when we have default parameters.
             See https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Functions/Default_parameters#scope_effects
          *)
          let param_bindings =
            let hoist = new hoister ~flowmin_compatibility ~enable_enums ~with_types in
            run hoist#function_params params;
            hoist#acc
          in
          (* We need to visit function param default expressions without bindings
             inside the function body. *)
          this#with_bindings
            ~lexical:true
            body_loc
            param_bindings
            (fun () -> run this#function_params params)
            ()
        end;
        (* We have already visited the defaults in their own scope. Now visit the
           parameter types, each in a separate scope that includes bindings for each
           parameter name that has been seen before in the parameter list. *)
        let (params_loc, { Params.params = params_list; this_; rest; comments = params_comments }) =
          params_without_defaults
        in
        (* this-param *)
        let this_ =
          Base.Option.map this_ ~f:(fun this_ ->
              let (_, { ThisParam.annot; _ }) = this_ in
              let (annot_loc, _) = annot in
              this#with_bindings
                annot_loc
                Bindings.empty
                (fun () -> run this#type_annotation annot)
                ();
              this_
          )
        in

        let hoist = new hoister ~flowmin_compatibility ~enable_enums ~with_types in
        (* Parameter list *)
        let params_list_rev =
          Base.List.fold_left params_list ~init:[] ~f:(fun prev_params param ->
              let (param_loc, { Param.argument; default }) = param in
              let (annot, argument') = pattern_with_toplevel_annot_removed argument in
              (match annot with
              | Ast.Type.Available annot ->
                let (annot_loc, _) = annot in
                this#with_bindings
                  annot_loc
                  hoist#acc
                  (fun () ->
                    (* All previous params need to be declared in the current scope *)
                    List.rev prev_params |> List.iter (run this#function_param);
                    run this#type_annotation annot)
                  ()
              | Ast.Type.Missing _ -> ());
              run hoist#function_param param;
              (param_loc, { Param.argument = argument'; default }) :: prev_params
          )
        in
        (* Rest param *)
        let rest =
          Base.Option.map rest ~f:(fun rest ->
              let (rest_loc, { RestParam.argument; comments }) = rest in
              let (annot, argument') = pattern_with_toplevel_annot_removed argument in
              (match annot with
              | Ast.Type.Available annot ->
                let (annot_loc, _) = annot in
                this#with_bindings
                  annot_loc
                  hoist#acc
                  (fun () ->
                    (* All previous params need to be declared in the current scope *)
                    List.rev params_list_rev |> List.iter (run this#function_param);
                    run this#type_annotation annot)
                  ()
              | Ast.Type.Missing _ -> ());
              run hoist#function_rest_param rest;
              (rest_loc, { RestParam.argument = argument'; comments })
          )
        in
        let params_without_toplevel_annots =
          ( params_loc,
            { Params.params = List.rev params_list_rev; this_; rest; comments = params_comments }
          )
        in
        (* return *)
        let () =
          match return with
          | ReturnAnnot.Missing _ -> ()
          | ReturnAnnot.Available (_, (loc, _))
          | ReturnAnnot.TypeGuard (loc, _) ->
            this#with_bindings
              loc
              hoist#acc
              (fun () ->
                if with_types then (
                  run this#function_params params_without_toplevel_annots;
                  run this#function_return_annotation return
                ))
              ()
        in
        (* Finally, visit the body in a scope that includes bindings for all params
           and hoisted body declarations. *)
        let bindings =
          run hoist#function_body_any body;
          hoist#acc
        in
        (* We have already visited the defaults in their own scope. Now visit the
           params without the defaults in the function's scope. *)
        this#with_bindings
          body_loc
          bindings
          (fun () ->
            run this#function_params params_without_toplevel_annots;
            run_opt this#predicate predicate;
            run this#function_body_any body)
          ()

      method! declare_module _loc m =
        let open Ast.Statement.DeclareModule in
        let { id = _; body; kind = _; comments = _ } = m in
        let (loc, body) = body in
        let bindings =
          let hoist = new hoister ~flowmin_compatibility ~enable_enums ~with_types in
          run (hoist#block loc) body;
          hoist#acc
        in
        this#with_bindings loc bindings (fun () -> run (this#block loc) body) ();
        m

      method private scoped_type_params ?(hoist_op = (fun f -> f ())) ~in_tparam_scope tparams =
        let open Ast.Type.TypeParams in
        let open Ast.Type.TypeParam in
        let tps =
          Base.Option.value_map ~f:(fun (_, tparams) -> tparams.params) ~default:[] tparams
        in
        let rec loop tps =
          match tps with
          | (loc, { name; bound; bound_kind = _; variance; default }) :: next ->
            hoist_op (fun () -> ignore @@ this#type_annotation_hint bound);
            ignore @@ this#variance_opt variance;
            hoist_op (fun () -> ignore @@ Base.Option.map ~f:this#type_ default);
            let bindings = Bindings.(singleton (name, Bindings.Type { imported = false })) in
            this#with_bindings
              loc
              bindings
              (fun () ->
                ignore @@ this#binding_type_identifier name;
                loop next)
              ()
          | [] -> in_tparam_scope ()
        in
        if with_types then
          loop tps
        else
          in_tparam_scope ()

      method private hoist_annotations f = f ()

      method private scoped_infer_type_params ~in_tparam_scope loc tps =
        if with_types then (
          let open Ast.Type.TypeParam in
          (* Unlike other tparams, infer types' tparams don't have an obvious order,
             so bounds in infer cannot refer to other infer types in the same hoisted list. *)
          Base.List.iter tps ~f:(fun (_, { bound; default; _ }) ->
              ignore @@ this#type_annotation_hint bound;
              ignore @@ Base.Option.map ~f:this#type_ default
          );
          let bindings =
            Base.List.fold tps ~init:Bindings.empty ~f:(fun bindings (_, { name; _ }) ->
                Bindings.add (name, Bindings.Type { imported = false }) bindings
            )
          in
          this#with_bindings
            loc
            bindings
            (fun () ->
              Base.List.iter tps ~f:(fun (_, { name; _ }) ->
                  ignore @@ this#binding_infer_type_identifier name
              );
              in_tparam_scope ())
            ()
        ) else
          in_tparam_scope ()

      method private binding_infer_type_identifier name = this#binding_type_identifier name

      method! conditional_type t =
        let open Ast.Type.Conditional in
        let { check_type; extends_type; true_type; false_type; comments = _ } = t in
        ignore @@ this#type_ check_type;
        ignore @@ this#extends_in_infer_type extends_type;
        let tparams =
          Infer_type_hoister.hoist_infer_types extends_type
          |> Base.List.map ~f:(fun (_, { Ast.Type.Infer.tparam; _ }) -> tparam)
        in
        this#scoped_infer_type_params
          ~in_tparam_scope:(fun () -> ignore @@ this#type_ true_type)
          (fst extends_type)
          tparams;
        ignore @@ this#type_ false_type;
        t

      method private extends_in_infer_type = this#type_

      (* Visits of infer type are skipped, because they are handled in conditional type above *)
      method! infer_type t = t

      method private this_binding_function_id_opt ~fun_loc:_ ~has_this_annot:_ ident =
        Base.Option.iter ident ~f:(fun id -> ignore @@ this#function_identifier id)

      method component_body_with_params ~component_loc:_ body params =
        (* In component syntax param types and defaults cannot reference other params, so we visit
         * the types and defaults without including the param bindings. *)
        let ( _,
              {
                Ast.Statement.ComponentDeclaration.Params.params = inline_params;
                rest = _;
                comments = _;
              }
            ) =
          params
        in
        List.iter
          (fun ( _,
                 {
                   Ast.Statement.ComponentDeclaration.Param.default;
                   local = _;
                   shorthand = _;
                   name = _;
                 }
               ) -> Base.Option.iter default ~f:(fun default -> ignore @@ this#expression default))
          inline_params;
        let params_without_annots_and_defaults =
          let visitor = new component_annot_collector_and_default_remover in
          let params = visitor#component_params params in
          (* Visit all of the annotations without any additional bindings *)
          visitor#acc |> Base.List.rev |> Base.List.iter ~f:(fun annot -> ignore @@ this#type_ annot);
          params
        in
        let bindings =
          let hoist = new hoister ~flowmin_compatibility ~enable_enums ~with_types in
          run hoist#component_params params;
          hoist#acc
        in
        this#with_bindings
          (fst params)
          bindings
          (fun () ->
            (* This is to ensure that params are declared *)
            run this#component_params params_without_annots_and_defaults;
            run this#component_body body)
          ()

      method! component_declaration loc (expr : (L.t, L.t) Ast.Statement.ComponentDeclaration.t) =
        let skip_scope =
          flowmin_compatibility
          &&
          let visit = new with_or_eval_visitor in
          visit#eval (visit#component_declaration loc) expr
        in
        if not skip_scope then (
          let open Ast.Statement.ComponentDeclaration in
          let { id; params; body; renders; tparams; sig_loc = _; comments = _ } = expr in
          ignore @@ this#component_identifier id;
          this#scoped_type_params
            ~hoist_op:this#hoist_annotations
            tparams
            ~in_tparam_scope:(fun () ->
              this#component_body_with_params ~component_loc:loc body params;
              if with_types then
                this#hoist_annotations (fun () -> ignore @@ this#type_annotation_hint renders)
          )
        );
        expr

      method! declare_component loc (expr : (L.t, L.t) Ast.Statement.DeclareComponent.t) =
        let skip_scope =
          flowmin_compatibility
          &&
          let visit = new with_or_eval_visitor in
          visit#eval (visit#declare_component loc) expr
        in
        if not skip_scope then (
          let open Ast.Statement.DeclareComponent in
          let { id = ident; tparams; params; renders; comments = _ } = expr in
          ignore @@ this#component_identifier ident;
          this#scoped_type_params
            ~hoist_op:this#hoist_annotations
            tparams
            ~in_tparam_scope:(fun () ->
              let _ = this#component_type_params params in
              this#hoist_annotations (fun () -> ignore @@ this#type_annotation_hint renders)
          )
        );
        expr

      method! function_declaration loc (expr : (L.t, L.t) Ast.Function.t) =
        let skip_scope =
          flowmin_compatibility
          &&
          let visit = new with_or_eval_visitor in
          visit#eval (visit#function_declaration loc) expr
        in
        if not skip_scope then (
          let open Ast.Function in
          let {
            id;
            params = (_, { Ast.Function.Params.this_; _ }) as params;
            body;
            return;
            tparams;
            async = _;
            generator;
            predicate;
            sig_loc = _;
            comments = _;
          } =
            expr
          in
          this#this_binding_function_id_opt
            ~fun_loc:loc
            ~has_this_annot:(Base.Option.is_some this_)
            id;
          let generator_return_loc =
            let open Ast.Function.ReturnAnnot in
            match (generator, return) with
            | (false, _) -> None
            | (true, (Available (loc, _) | Missing loc | TypeGuard (loc, _))) -> Some loc
          in
          this#scoped_type_params
            ~hoist_op:this#hoist_annotations
            tparams
            ~in_tparam_scope:(fun () ->
              this#lambda
                ~is_arrow:false
                ~fun_loc:loc
                ~generator_return_loc
                params
                return
                predicate
                body
          )
        );

        expr

      (* Almost the same as function_declaration, except that the name of the
         function expression is locally in scope. *)
      method private function_expression_without_name ~is_arrow loc expr =
        let skip_scope =
          flowmin_compatibility
          &&
          let visit = new with_or_eval_visitor in
          visit#eval (visit#function_ loc) expr
        in
        ( if not skip_scope then
          let open Ast.Function in
          let {
            id;
            params = (_, { Ast.Function.Params.this_; _ }) as params;
            body;
            return;
            tparams;
            async = _;
            generator;
            predicate;
            sig_loc = _;
            comments = _;
          } =
            expr
          in
          let bindings =
            match id with
            | Some name -> Bindings.(singleton (name, Bindings.Function))
            | None -> Bindings.empty
          in
          let generator_return_loc =
            let open Ast.Function.ReturnAnnot in
            match (generator, return) with
            | (false, _) -> None
            | (true, (Available (loc, _) | Missing loc | TypeGuard (loc, _))) -> Some loc
          in
          this#with_bindings
            loc
            ~lexical:true
            bindings
            (fun () ->
              if is_arrow then
                run_opt this#function_identifier id
              else
                this#this_binding_function_id_opt
                  ~fun_loc:loc
                  ~has_this_annot:(Base.Option.is_some this_)
                  id;
              (* This function is not hoisted, so we just traverse the signature *)
              this#scoped_type_params tparams ~in_tparam_scope:(fun () ->
                  this#lambda
                    ~is_arrow
                    ~fun_loc:loc
                    ~generator_return_loc
                    params
                    return
                    predicate
                    body
              ))
            ()
        );
        expr

      method! function_ loc (expr : (L.t, L.t) Ast.Function.t) =
        this#function_expression_without_name ~is_arrow:false loc expr

      method! arrow_function loc (expr : (L.t, L.t) Ast.Function.t) =
        this#function_expression_without_name ~is_arrow:true loc expr

      method! declare_variable _ decl =
        let open Ast.Statement.DeclareVariable in
        let { id = ident; annot; kind; comments = _ } = decl in
        ignore @@ this#pattern_identifier ~kind ident;
        this#hoist_annotations (fun () -> ignore @@ this#type_annotation annot);
        decl

      method! declare_function loc expr =
        match Declare_function_utils.declare_function_to_function_declaration_simple loc expr with
        | Some stmt ->
          let _ = this#statement (loc, stmt) in
          expr
        | None ->
          let _ = super#declare_function loc expr in
          let { Ast.Statement.DeclareFunction.annot; _ } = expr in
          ignore @@ this#hoist_annotations (fun () -> ignore @@ this#type_annotation annot);
          expr

      method! function_type _loc (ft : ('loc, 'loc) Ast.Type.Function.t) =
        let open Ast.Type.Function in
        let {
          params = (_, { Params.this_; params = ps; rest = rpo; comments = _ });
          return;
          tparams;
          comments = _;
        } =
          ft
        in
        let in_tparam_scope () =
          ignore @@ Base.Option.map ~f:this#function_this_param_type this_;
          ignore @@ Base.List.map ~f:this#function_param_type ps;
          ignore @@ Base.Option.map ~f:this#function_rest_param_type rpo;
          ignore @@ this#function_type_return_annotation return
        in
        this#scoped_type_params tparams ~in_tparam_scope;
        ft

      method! component_type _loc (t : ('loc, 'loc) Ast.Type.Component.t) =
        let open Ast.Type.Component in
        let { tparams; params; renders; comments = _ } = t in
        let in_tparam_scope () =
          let _params' = this#component_type_params params in
          let _renders' = this#type_annotation_hint renders in
          ()
        in
        this#scoped_type_params tparams ~in_tparam_scope;
        t

      method! object_mapped_type_property mt =
        let open Ast.Type.Object.MappedType in
        let (_, { key_tparam; prop_type; source_type; variance = _; optional = _; comments = _ }) =
          mt
        in
        let tparams =
          Some (fst key_tparam, { Ast.Type.TypeParams.params = [key_tparam]; comments = None })
        in
        ignore @@ this#type_ source_type;
        let in_tparam_scope () = ignore @@ this#type_ prop_type in
        this#scoped_type_params tparams ~in_tparam_scope;
        mt

      method! class_expression loc cls =
        let { Ast.Class.id; _ } = cls in
        let bindings =
          match id with
          | Some name -> Bindings.(singleton (name, Bindings.Class))
          | None -> Bindings.empty
        in
        this#with_bindings
          loc
          ~lexical:true
          bindings
          (fun () -> ignore (super#class_expression loc cls : ('a, 'b) Ast.Class.t))
          ();
        cls

      method! class_ loc (cls : ('loc, 'loc) Ast.Class.t) =
        let open Ast.Class in
        let { id; body; tparams; extends; implements; class_decorators; comments = _ } = cls in
        ignore @@ Base.List.map ~f:this#class_decorator class_decorators;
        let extends_targs =
          Base.Option.value_map
            extends
            ~default:None
            ~f:(fun (_, { Ast.Class.Extends.expr; targs; comments = _ }) ->
              ignore @@ this#expression expr;
              targs
          )
        in
        this#class_identifier_opt ~class_loc:loc id;
        let implements_targs =
          Base.Option.value_map
            implements
            ~default:[]
            ~f:(fun (_, { Ast.Class.Implements.interfaces; comments = _ }) ->
              Base.List.filter_map
                interfaces
                ~f:(fun (_, { Ast.Class.Implements.Interface.id; targs }) ->
                  ignore @@ this#type_identifier_reference id;
                  targs
              )
          )
        in
        let in_tparam_scope () =
          ignore @@ Base.Option.map ~f:this#type_args extends_targs;
          ignore @@ Base.List.map ~f:this#type_args implements_targs;
          ignore @@ this#class_body body
        in
        this#scoped_type_params tparams ~in_tparam_scope;
        cls

      method private class_identifier_opt ~class_loc:_ id =
        ignore @@ Base.Option.map ~f:this#class_identifier id

      method! declare_class _loc (decl : ('loc, 'loc) Ast.Statement.DeclareClass.t) =
        let open Ast.Statement.DeclareClass in
        let { id; tparams; body = (body_loc, body); extends; mixins; implements; comments = _ } =
          decl
        in
        ignore @@ this#class_identifier id;
        let extends_targs =
          Base.Option.value_map
            extends
            ~default:None
            ~f:(fun (_ext_loc, { Ast.Type.Generic.id; targs; comments = _ }) ->
              ignore @@ this#generic_identifier_type id;
              targs
          )
        in
        let mixins_targs =
          Base.List.filter_map mixins ~f:(fun (_, { Ast.Type.Generic.id; targs; comments = _ }) ->
              ignore @@ this#generic_identifier_type id;
              targs
          )
        in
        let implements_targs =
          Base.Option.value_map
            implements
            ~default:[]
            ~f:(fun (_, { Ast.Class.Implements.interfaces; comments = _ }) ->
              Base.List.filter_map
                interfaces
                ~f:(fun (_, { Ast.Class.Implements.Interface.id; targs }) ->
                  ignore @@ this#type_identifier_reference id;
                  targs
              )
          )
        in
        let in_tparam_scope () =
          ignore @@ Base.Option.map ~f:this#type_args extends_targs;
          ignore @@ Base.List.map ~f:this#type_args mixins_targs;
          ignore @@ Base.List.map ~f:this#type_args implements_targs;
          ignore @@ this#object_type body_loc body
        in
        this#scoped_type_params tparams ~in_tparam_scope;
        decl

      method! enum_declaration loc (enum : ('loc, 'loc) Ast.Statement.EnumDeclaration.t) =
        if not enable_enums then
          enum
        else
          super#enum_declaration loc enum
    end

  let program ?(flowmin_compatibility = false) ~enable_enums ~with_types program =
    let (loc, _) = program in
    let walk = new scope_builder ~flowmin_compatibility ~enable_enums ~with_types in
    let bindings =
      if flowmin_compatibility then
        let hoist = new lexical_hoister ~flowmin_compatibility ~enable_enums in
        hoist#eval hoist#program program
      else
        let hoist = new hoister ~flowmin_compatibility ~enable_enums ~with_types in
        hoist#eval hoist#program program
    in
    walk#eval (walk#with_bindings loc bindings walk#program) program
end

module With_Loc = Make (Loc_sig.LocS) (Scope_api.With_Loc)
module With_ALoc = Make (Loc_sig.ALocS) (Scope_api.With_ALoc)
module With_ILoc = Make (Loc_sig.ILocS) (Scope_api.With_ILoc)
include With_Loc
