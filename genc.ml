open Ast
open Common
open Type

(*
	Naming conventions:
		e = Type.texpr
		t = Type.t
		p = Ast.pos
		c = Type.tclass
		cf = Type.tclass_field
		*l = ... list
		*o = ... option

	Function names:
		generate_ -> outputs content to buffer
		s_ -> return string

*)

type dependency_type =
	| DFull
	| DForward
	| DCStd

type function_context = {
	field : tclass_field;
	mutable loop_stack : string option list;
	mutable meta : metadata;
}

type hxc = {
	t_typeref : t -> t;
	t_pointer : t -> t;
	t_const_pointer : t -> t;
	t_func_pointer : t -> t;
	t_closure : t -> t;
	t_int64 : t -> t;
	t_jmp_buf : t;
	t_vararg : t;

	c_lib : tclass;
	c_boot : tclass;
	c_string : tclass;
	c_array : tclass;
	c_fixed_array : tclass;
	c_exception : tclass;
	c_cstring : tclass;
	c_csetjmp : tclass;
	c_cstdlib : tclass;
	c_cstdio : tclass;
	c_vtable : tclass;

	cf_deref : tclass_field;
	cf_addressof : tclass_field;
	cf_sizeof : tclass_field;
}

type context = {
	com : Common.context;
	hxc : hxc;
	mutable num_temp_funcs : int;
	mutable num_labels : int;
	mutable num_identified_types : int;
	mutable get_anon_signature : (string,tclass_field) PMap.t -> string;
	mutable type_ids : (string,int) PMap.t;
	mutable type_parameters : (path, texpr) PMap.t;
	mutable init_modules : path list;
	mutable generated_types : type_context list;
}

and type_context = {
	con : context;
	file_path_no_ext : string;
	buf_c : Buffer.t;
	buf_h : Buffer.t;
	type_path : path;
	mutable buf : Buffer.t;
	mutable tabs : string;
	mutable fctx : function_context;
	mutable dependencies : (path,dependency_type) PMap.t;
}

and gen_context = {
	gcom : Common.context;
	gcon : context;
	mutable gfield : tclass_field;
	mutable gstat  : bool;
	mutable gclass : tclass;
	(* call this function instead of Type.map_expr () *)
	mutable map : texpr -> texpr;
	(* tvar_decl -> unit; declares a variable on the current block *)
	mutable declare_var : (tvar * texpr option) -> unit;
	mutable declare_temp : t -> texpr option -> tvar;
	(* runs a filter on the specified class field *)
	mutable run_filter : tclass_field -> bool -> unit;
	(* adds a field to the specified class *)
	mutable add_field : tclass -> tclass_field -> bool -> unit;
	mutable filters : filter list;
}

and filter = gen_context->(texpr->texpr)

type answer =
	| Yes
	| No
	| Maybe

let rec follow t =
	match t with
	| TMono r ->
		(match !r with
		| Some t -> follow t
		| _ -> t)
	| TLazy f ->
		follow (!f())
	| TType (t,tl) ->
		follow (apply_params t.t_types tl t.t_type)
	| TAbstract(a,pl) when not (Meta.has Meta.CoreType a.a_meta) ->
		follow (Codegen.Abstract.get_underlying_type a pl)
	| _ -> t


(* Helper *)

let path_to_name (pack,name) = match pack with [] -> name | _ -> String.concat "_" pack ^ "_" ^ name

let get_type_id con t =
	let id = Type.s_type (print_context()) (follow t) in
	try
		PMap.find id con.type_ids
	with Not_found ->
		con.num_identified_types <- con.num_identified_types + 1;
		con.type_ids <- PMap.add id con.num_identified_types con.type_ids;
		con.num_identified_types

let sort_anon_fields fields =
	List.sort (fun cf1 cf2 ->
		match Meta.has Meta.Optional cf1.cf_meta, Meta.has Meta.Optional cf2.cf_meta with
		| false,false | true,true -> compare cf1.cf_name cf2.cf_name
		| true, false -> 1
		| false, true -> -1
	) fields

let pmap_to_list pm = PMap.fold (fun v acc -> v :: acc) pm []

let mk_runtime_prefix n = "_hx_" ^ n

let alloc_temp_func con =
	let id = con.num_temp_funcs in
	con.num_temp_funcs <- con.num_temp_funcs + 1;
	let name = mk_runtime_prefix ("func_" ^ (string_of_int id)) in
	name

module Expr = struct

	let t_path t = match follow t with
		| TInst(c,_) -> c.cl_path
		| TEnum(e,_) -> e.e_path
		| TAbstract(a,_) -> a.a_path
		| _ -> [],"Dynamic"

	let mk_static_field c cf p =
		let ta = TAnon { a_fields = c.cl_statics; a_status = ref (Statics c) } in
		let ethis = mk (TTypeExpr (TClassDecl c)) ta p in
		let t = monomorphs cf.cf_params cf.cf_type in
		mk (TField (ethis,(FStatic (c,cf)))) t p

	let mk_static_call c cf el p =
		let ef = mk_static_field c cf p in
		let tr = match follow ef.etype with
			| TFun(args,tr) -> tr
			| _ -> assert false
		in
		mk (TCall(ef,el)) tr p

	let mk_static_field_2 c n p =
		mk_static_field c (PMap.find n c.cl_statics) p

	let mk_static_call_2 c n el p =
		mk_static_call c (PMap.find n c.cl_statics) el p

	let mk_local v p =
		{ eexpr = TLocal v; etype = v.v_type; epos = p }

	let mk_block com p el =
		let t = match List.rev el with
			| [] -> com.basic.tvoid
			| hd :: _ -> hd.etype
		in
		mk (TBlock el) t p

	let mk_cast e t =
		{ e with eexpr = TCast(e, None); etype = t }

	let mk_deref hxc p e =
		mk_static_call hxc.c_lib hxc.cf_deref [e] p

	let mk_ccode con s p =
		mk_static_call_2 con.hxc.c_lib "cCode" [mk (TConst (TString s)) con.com.basic.tstring p] p

	let mk_int com i p =
		mk (TConst (TInt (Int32.of_int i))) com.basic.tint p

	let mk_string com s p =
		mk (TConst (TString s)) com.basic.tstring p

	let debug ctx e =
		Printf.sprintf "%s: %s" ctx.fctx.field.cf_name (s_expr (s_type (print_context())) e)

	let mk_class_field name t public pos kind params =
		{
			cf_name = name;
			cf_type = t;
			cf_public = public;
			cf_pos = pos;
			cf_doc = None;
			cf_meta = [ Meta.CompilerGenerated, [], Ast.null_pos ]; (* annotate that this class field was generated by the compiler *)
			cf_kind = kind;
			cf_params = params;
			cf_expr = None;
			cf_overloads = [];
		}

	let mk_binop op e1 e2 et p =
		{ eexpr=TBinop(op,e1,e2); etype=et; epos=p }

	let mk_obj_decl fields p =
		let fields = List.sort compare fields in
		let t_fields = List.fold_left (fun acc (n,e) ->
			let cf = mk_class_field n e.etype true e.epos (Var {v_read = AccNormal; v_write = AccNormal}) [] in
			PMap.add n cf acc
		) PMap.empty fields in
		let t = TAnon {a_fields = t_fields; a_status = ref Closed} in
		mk (TObjectDecl fields) t p

	let insert_expr e once f =
		let el = match e.eexpr with TBlock el -> el | _ -> [e] in
		let el,found = List.fold_left (fun (acc,found) e ->
			match f e with
			| Some e1 when not once || not found -> e :: e1 :: acc,true
			| _ -> e :: acc,found
		) ([],false) el in
		mk (TBlock (List.rev el)) e.etype e.epos,found

	let add_meta m e =
		mk (TMeta((m,[],e.epos),e)) e.etype e.epos

end

module Wrap = struct

	(* string wrapping *)
	let wrap_string hxc e =
		Expr.mk_static_call_2 hxc.c_string "ofPointerCopyNT" [e] e.epos

	(* basic type wrapping *)

	let box_field_name =
		mk_runtime_prefix "value"

	let mk_box_field t =
		Expr.mk_class_field box_field_name t true Ast.null_pos (Var {v_read = AccNormal;v_write=AccNormal}) []

 	let mk_box_type t =
	 	TAnon {
			a_status = ref Closed;
			a_fields = PMap.add box_field_name (mk_box_field t) PMap.empty
		}

	let requires_wrapping t = match follow t with
		| TAbstract({a_path=[],("Int" | "Float" | "Bool")},_) ->
			true
		| _ ->
			false

	let box_basic_value e =
		if is_null e.etype || not (requires_wrapping e.etype) then
			e
		else begin
			let t = follow e.etype in
			let e = Expr.mk_obj_decl [box_field_name,{e with etype = t}] e.epos in
			Expr.mk_cast e t
		end

	let unbox_basic_value e =
		if not (is_null e.etype) || not (requires_wrapping e.etype) then
			e
		else begin
			let t = follow e.etype in
			let cf = mk_box_field t in
			let e = mk (TField(e,FAnon cf)) t e.epos in
			Expr.mk_cast e t
		end

	(* closure wrapping *)

	let wrap_function hxc ethis efunc =
		let c,t = match hxc.t_closure efunc.etype with TInst(c,_) as t -> c,t | _ -> assert false in
		let cf_func = PMap.find "_func" c.cl_fields in
		mk (TNew(c,[efunc.etype],[Expr.mk_cast efunc cf_func.cf_type;ethis])) t efunc.epos

	let wrap_static_function hxc efunc =
		wrap_function hxc (mk (TConst TNull) (mk_mono()) efunc.epos) efunc

	(* dynamic wrapping *)

	let st = s_type (print_context())

	let is_dynamic t = match follow t with
		| TDynamic _ -> true
		| _ -> false

	let wrap_dynamic con e =
		con.com.warning (Printf.sprintf "Wrapping dynamic %s" (st e.etype)) e.epos;
		e

	let unwrap_dynamic con e t =
		con.com.warning (Printf.sprintf "Unwrapping dynamic %s" (s_expr_pretty "" st e)) e.epos;
		e
end


(* Filters *)

module Filters = struct

	let add_filter gen filter =
		gen.filters <- filter :: gen.filters

	let run_filters gen e =
		(* local vars / temp vars handling *)
		let declared_vars = ref [] in
		let temp_var_counter = ref (-1) in

		(* temporary var handling *)
		let old_declare = gen.declare_var in
		gen.declare_var <- (fun (tvar,eopt) ->
			declared_vars := (tvar,eopt) :: !declared_vars;
		);
		gen.declare_temp <- (fun t eopt ->
			incr temp_var_counter;
			let v = alloc_var ("_tmp" ^ (string_of_int !temp_var_counter)) t in
			gen.declare_var (v,eopt);
			v
		);

		let ret = List.fold_left (fun e f ->
			let found_block = ref false in
			let run = f gen in
			let rec map e = match e.eexpr with
				| TFunction tf when not !found_block ->
					(* if there were no blocks yet, declare inside the top-level TFunction *)
					let ret = run { e with eexpr = TFunction { tf with tf_expr = mk_block tf.tf_expr } } in
					(match !declared_vars with
					| [] -> ret
					| vars ->
						let expr = { eexpr = TVars(List.rev vars); etype = gen.gcom.basic.tvoid; epos = ret.epos } in
						declared_vars := [];
						match ret.eexpr with
						| TFunction tf ->
							let tf_expr = Codegen.concat expr tf.tf_expr in
							{ ret with eexpr = TFunction { tf with tf_expr = tf_expr } }
						| _ ->
							let expr = Codegen.concat expr ret in
							expr)
				| TBlock(el) ->
					let old_declared = !declared_vars in
					found_block := true;
					declared_vars := [];
					(* run loop *)
					let el = match (mk_block (run e)).eexpr with
						| TBlock el -> el
						| _ -> assert false
					in
					(* change loop with new declared vars *)
					let el = match !declared_vars with
						| [] -> el
						| vars ->
							{ eexpr = TVars(List.rev vars); etype = gen.gcom.basic.tvoid; epos = e.epos } :: el
					in
					let ret = { e with eexpr = TBlock(el) } in
					declared_vars := old_declared;
					ret
				| _ -> run e
			in

			let last_map = gen.map in
			gen.map <- map;
			let ret = map e in
			gen.map <- last_map;
			ret
		) e gen.filters in
		gen.declare_var <- old_declare;
		ret

	let run_filters_field gen stat cf =
		gen.gfield <- cf;
		gen.gstat  <- stat;
		match cf.cf_expr with
		| None -> ()
		| Some e ->
			cf.cf_expr <- Some (run_filters gen e)

	let mk_gen_context con =
		let rec gen = {
			gcom = con.com;
			gcon = con;
			gfield = null_field;
			gstat  = false;
			gclass = null_class;
			filters = [];
			map = (function _ -> assert false);
			declare_var = (fun _ -> assert false);
			declare_temp = (fun _ _ -> assert false);
			run_filter = (fun _ _ -> assert false);
			add_field = (fun c cf stat ->
				gen.run_filter cf stat;
				if stat then begin
					c.cl_ordered_statics <- cf :: c.cl_ordered_statics;
					c.cl_statics <- PMap.add cf.cf_name cf c.cl_statics;
				end else begin
					c.cl_ordered_fields <- cf :: c.cl_ordered_fields;
					c.cl_fields <- PMap.add cf.cf_name cf c.cl_fields;
				end);
		} in
		gen

	let run_filters_types gen =
		List.iter (fun md -> match md with
			| TClassDecl c ->
				gen.gclass <- c;
				let added = ref [] in
				let old_run_filter = gen.run_filter in
				gen.run_filter <- (fun cf stat ->
					added := (cf,stat) :: !added);

				let fields = c.cl_ordered_fields in
				let statics = c.cl_ordered_statics in
				Option.may (run_filters_field gen false) c.cl_constructor;
				List.iter (run_filters_field gen false) fields;
				List.iter (run_filters_field gen true) statics;
				gen.gfield <- null_field;
				c.cl_init <- Option.map (run_filters gen) c.cl_init;

				(* run all added fields *)
				let rec loop () = match !added with
					| [] -> ()
					| (hd,stat) :: tl ->
						added := tl;
						run_filters_field gen stat hd;
						loop ()
				in
				loop();
				gen.run_filter <- old_run_filter
			| _ -> ()
		) gen.gcon.com.types

end


(*
	This filter will take all out-of-place TVars declarations and add to the beginning of each block.
	TPatMatch has some var names sanitized.
*)
module VarDeclarations = struct

	let filter gen = function e ->
		match e.eexpr with
		| TVars [{v_name = "this"},_] ->
			e
		| TVars tvars ->
			let el = ExtList.List.filter_map (fun (v,eo) ->
				gen.declare_var (v,None);
				match eo with
				| None -> None
				| Some e -> Some { eexpr = TBinop(Ast.OpAssign, Expr.mk_local v e.epos, gen.map e); etype = e.etype; epos = e.epos }
			) tvars in
			(match el with
			| [e] -> e
			| _ -> Expr.mk_block gen.gcom e.epos el)
		| _ ->
			Type.map_expr gen.map e

end


(*
	Transforms (x = value) function arguments to if (x == null) x = value expressions.
	Must run before VarDeclarations or the universe implodes.
*)
module DefaultValues = struct

	type function_mode =
		| Given
		| Mixed
		| Default

	let get_fmode tf t =
		try
			let args = match follow t with TFun(args,_) -> args | _ -> raise Exit in
			let rec loop has_default args1 args2 = match args1,args2 with
				| ((v,co) :: args1),((n,o,t) :: args2) ->
					begin match o,co with
						| true,None
						| true,Some TNull -> Mixed
						| _,Some _ -> loop true args1 args2
						| false,None -> loop has_default args1 args2
					end
				| [],[] ->
					if has_default then Default else Given
				| _ ->
					Mixed
			in
			loop false tf.tf_args args
		with Exit ->
			Mixed

	let fstack = ref []

	let filter gen = function e ->
		match e.eexpr with
		| TFunction tf ->
			let p = e.epos in
			fstack := tf :: !fstack;
			let replace_locals subst e =
				let v_this = ref None in
				let rec replace e = match e.eexpr with
					| TLocal v ->
						begin try
							let vr = List.assq v subst in
							mk (TLocal vr) vr.v_type e.epos
						with Not_found ->
							e
						end
					| TConst TThis ->
						v_this := Some (alloc_var "this" e.etype);
						e
					| _ ->
						Type.map_expr replace e
				in
				replace e,!v_this
			in
			let handle_default_assign e =
				let subst,el = List.fold_left (fun (subst,el) (v,co) ->
					match co with
					| None ->
						subst,el
					| Some TNull ->
						subst,el
					| Some c ->
						let e_loc_v = Expr.mk_local v p in
						let e_loc_v2,subst = if Wrap.requires_wrapping v.v_type then begin
							let temp = gen.declare_temp (follow v.v_type) None in
							Expr.mk_local temp p,((v,temp) :: subst)
						end else
							e_loc_v,subst
						in
						let econd = Codegen.mk_parent (Codegen.binop OpEq (mk (TConst TNull) (mk_mono())p) e_loc_v gen.gcom.basic.tbool p) in
						let mk_assign e2 = Codegen.binop OpAssign e_loc_v2 e2 e2.etype p in
						let eassign = mk_assign (mk (TConst c) (follow v.v_type) p) in
						let eelse = if Wrap.requires_wrapping v.v_type then begin
							Some (mk_assign (Wrap.unbox_basic_value e_loc_v))
						end else
							None
						in
						let eif = mk (TIf(econd,eassign,eelse)) gen.gcom.basic.tvoid p in
						subst,(eif :: el)
				) ([],[]) tf.tf_args in
				let el = (fst (replace_locals subst e)) :: el in
				Expr.mk_block gen.gcom p (List.rev el)
			in
			let e = match get_fmode tf e.etype with
				| Default ->
					let is_field_func = match !fstack with [_] -> true | _ -> false in
					let name = if is_field_func then (mk_runtime_prefix ("known_" ^ gen.gfield.cf_name)) else alloc_temp_func gen.gcon in
					let subst,tf_args = List.fold_left (fun (subst,args) (v,_) ->
						let vr = alloc_var v.v_name (follow v.v_type) in
						((v,vr) :: subst),((vr,None) :: args)
					) ([],[]) tf.tf_args in
					let tf_args = List.rev tf_args in
					let e_tf,v_this = replace_locals subst tf.tf_expr in
					let tf_args = match v_this with
						| None -> tf_args
						| Some v -> (v,None) :: tf_args
					in
					let tf_given = {
						tf_args = tf_args;
						tf_type = tf.tf_type;
						tf_expr = gen.map e_tf;
					} in
					let t_cf = TFun(List.map (fun (v,_) -> v.v_name,false,follow v.v_type) tf_args,tf.tf_type) in
					let cf_given = Expr.mk_class_field name t_cf true p (Method MethNormal) [] in
					cf_given.cf_expr <- Some (mk (TFunction tf_given) cf_given.cf_type p);
					gen.add_field gen.gclass cf_given true;
					if is_field_func then gen.gfield.cf_meta <- (Meta.Custom ":known",[(EConst(String name)),p],p) :: gen.gfield.cf_meta;
					let e_args = List.map (fun (v,_) -> Expr.mk_local v p) tf.tf_args in
					let e_args = match v_this with
						| None -> e_args
						| Some v -> (mk (TConst TThis) v.v_type p) :: e_args
					in
					let e_call = Expr.mk_static_call gen.gclass cf_given e_args p in
					let e_call = handle_default_assign e_call in
					{ e with eexpr = TFunction({tf with tf_expr = e_call})}
				| Given ->
					{e with eexpr = TFunction{tf with tf_expr = gen.map tf.tf_expr}}
				| _ ->
					let e = handle_default_assign tf.tf_expr in
					{ e with eexpr = TFunction({tf with tf_expr = gen.map e})}
			in
			fstack := List.tl !fstack;
			e
		| TCall({eexpr = TField(_,FStatic({cl_path=["haxe"],"Log"},{cf_name="trace"}))}, e1 :: {eexpr = TObjectDecl fl} :: _) when not !Analyzer.assigns_to_trace ->
			let s = match follow e1.etype with
				| TAbstract({a_path=[],"Int"},_) -> "i"
				| TInst({cl_path=[],"String"},_) -> "s"
				| _ ->
					gen.gcom.warning "This will probably not work as expected" e.epos;
					"s"
			in
			let eformat = mk (TConst (TString ("%s:%ld: %" ^ s ^ "\\n"))) gen.gcom.basic.tstring e.epos in
			let eargs = mk (TArrayDecl [List.assoc "fileName" fl;List.assoc "lineNumber" fl;gen.map e1]) (gen.gcom.basic.tarray gen.gcon.hxc.t_vararg) e.epos in
			Expr.mk_static_call_2 gen.gcon.hxc.c_cstdio "printf" [eformat;eargs] e.epos
		| _ ->
			Type.map_expr gen.map e

	let rec is_null_expr e = match e.eexpr with
		| TConst TNull -> Yes
		| TConst _ | TObjectDecl _ | TArrayDecl _ | TFunction _ -> No
		| TParenthesis e1 | TMeta(_,e1) | TCast(e1,None) -> is_null_expr e1
		| _ ->
			if not (is_nullable e.etype) then No else Maybe

	let mk_known_call con c cf stat el =
		match cf.cf_expr with
		| Some ({eexpr = TFunction tf}) ->
			let rec loop args el = match args,el with
				| (_,Some co) :: args,([] as el | ({eexpr = TConst TNull} :: el)) ->
					(Codegen.mk_const_texpr con.com cf.cf_pos co) :: loop args el
				| _ :: args,e :: el ->
					(* cancel if we cannot tell whether or not the argument is null *)
					if is_null_expr e = Maybe then raise Exit;
					e :: loop args el
				| [],[] ->
					[]
				| _ ->
					assert false
			in
			let name = match Meta.get (Meta.Custom ":known") cf.cf_meta with
				| _,[EConst(String s),_],_ -> s
				| _ -> assert false
			in
			let has_this e =
				let rec loop e = match e.eexpr with
					| TConst TThis -> raise Exit
					| _ -> Type.iter loop e
				in
				try
					loop e;
					false;
				with Exit ->
					true
			in
			let el = if stat then
				loop tf.tf_args el
			else match el with
				| e :: el ->
					if has_this tf.tf_expr then
						 e :: loop tf.tf_args el
					else
						loop tf.tf_args el
				| [] ->
					assert false
			in
			Expr.mk_static_call_2 c name el cf.cf_pos
		| _ ->
			raise Exit

	let handle_call_site gen = function e ->
		match e.eexpr with
 		| TCall({eexpr = TField(_,FStatic(c,cf))},el) when Meta.has (Meta.Custom ":known") cf.cf_meta ->
			begin try gen.map (mk_known_call gen.gcon c cf true el)
			with Exit -> e end
 		| TCall({eexpr = TField(e1,FInstance(c,cf))},el) when Meta.has (Meta.Custom ":known") cf.cf_meta ->
			begin try gen.map (mk_known_call gen.gcon c cf false (e1 :: el))
			with Exit -> e end
		| TNew(c,tl,el) ->
			let _,cf = get_constructor (fun cf -> apply_params c.cl_types tl cf.cf_type) c in
			if Meta.has (Meta.Custom ":known") cf.cf_meta then
				begin try gen.map (mk_known_call gen.gcon c cf true el)
				with Exit -> e end
			else e
		| _ ->
			Type.map_expr gen.map e
end


(*
	This filter handles unification cases where AST transformation may be required.
	These occur in the following nodes:

		- TBinop(OpAssign,_,_)
		- TVars
		- TCall and TNew
		- TArrayDecl
		- TObjectDecl
		- TReturn

	It may perform the following transformations:
		- pad TObjectDecl with null for optional arguments
		- use Array as argument list to "rest" argument
		- box and unbox basic types
*)
module TypeChecker = struct

	let rec check gen e t =
		let e = match is_null e.etype,is_null t with
			| true,true
			| false,false -> e
			| true,false -> Wrap.unbox_basic_value e
			| false,true -> Wrap.box_basic_value e
		in
		let e = match Wrap.is_dynamic e.etype,Wrap.is_dynamic t with
			| true,true
			| false,false -> e
			| true,false ->
				begin match follow e.etype,follow t with
					| TMono _,_
					| _,TMono _ -> e
					| _ -> Wrap.unwrap_dynamic gen.gcon e t
				end
			| false,true ->
				begin match follow e.etype,follow t with
					| TMono _,_
					| _,TMono _ -> e
					| _ -> Wrap.wrap_dynamic gen.gcon e
				end
		in
		match e.eexpr,follow t with
		| TObjectDecl fl,(TAnon an as ta) ->
			let fields = sort_anon_fields (pmap_to_list an.a_fields) in
			let fl = List.map (fun cf ->
				try cf.cf_name,List.assoc cf.cf_name fl
				with Not_found -> cf.cf_name,mk (TConst TNull) (mk_mono()) e.epos
			) fields in
			{ e with eexpr = TObjectDecl fl; etype = ta}
		(* literal String assigned to const char* = pass through *)
		| TCall({eexpr = TField(_,FStatic({cl_path = [],"String"}, {cf_name = "ofPointerCopyNT"}))},[{eexpr = TConst (TString _)} as e]),(TAbstract({a_path = ["c"],"ConstPointer"},[TAbstract({a_path=[],"hx_char"},_)]) | TAbstract({a_path=["c"],"VarArg"},_)) ->
			e
		(* String assigned to const char* or VarArg = unwrap *)
		| _,(TAbstract({a_path=["c"],"VarArg"},_)) when (match follow e.etype with TInst({cl_path = [],"String"},_) -> true | _ -> false) ->
			Expr.mk_static_call_2 gen.gcon.hxc.c_string "raw" [e] e.epos
		| TMeta(m,e1),t ->
			{ e with eexpr = TMeta(m,check gen e1 t)}
		| TParenthesis(e1),t ->
			{ e with eexpr = TParenthesis(check gen e1 t)}
		| _ ->
			e

	let check_call_params gen el tl =
		let rec loop acc el tl = match el,tl with
			| e :: el, (n,_,t) :: tl ->
				(* check for rest argument *)
				begin match e.eexpr with
					| TArrayDecl el2 when n = "rest" && tl = [] && el = [] ->
						let ta = match follow e.etype with
							| TInst({cl_path=[],"Array"},[t]) -> t
							| _ -> t_dynamic
						in
						loop acc el2 (List.map (fun _ -> "rest",false,ta) el2)
					| _ ->
						loop ((check gen (gen.map e) t) :: acc) el tl
				end
			| [], [] ->
				acc
			| [],_ ->
				(* should not happen due to padded nulls *)
				assert false
			| _, [] ->
				(* not sure about this one *)
				assert false
		in
		List.rev (loop [] el tl)

	let fstack = ref []
	let is_call_expr = ref false

	let filter gen = function e ->
		match e.eexpr with
		| TBinop(OpAssign,e1,e2) ->
			{e with eexpr = TBinop(OpAssign,gen.map e1,check gen (gen.map e2) e1.etype)}
		| TBinop(OpEq | OpNotEq as op,e1,e2) ->
			{e with eexpr = TBinop(op,gen.map e1,gen.map e2)}
		| TBinop(op,e1,e2) ->
			{e with eexpr = TBinop(op,gen.map (Wrap.unbox_basic_value e1),gen.map (Wrap.unbox_basic_value e2))}
		| TVars vl ->
			let vl = ExtList.List.filter_map (fun (v,eo) ->
				match eo with
				| None -> Some(v,None)
				| Some e ->
					Some (v,Some (check gen (gen.map e) v.v_type))
			) vl in
			{ e with eexpr = TVars(vl)}
		| TLocal v ->
			{ e with etype = v.v_type }
		| TCall(e1,el) ->
			is_call_expr := true;
			let e1 = gen.map e1 in
			is_call_expr := false;
			begin match follow e1.etype with
				| TFun(args,_) | TAbstract({a_path = ["c"],"FunctionPointer"},[TFun(args,_)]) ->
					{e with eexpr = TCall(e1,check_call_params gen el args)}
				| _ -> Type.map_expr gen.map e
			end
		| TNew(c,tl,el) ->
			let tcf,_ = get_constructor (fun cf -> apply_params c.cl_types tl cf.cf_type) c in
			begin match follow tcf with
				| TFun(args,_) | TAbstract({a_path = ["c"],"FunctionPointer"},[TFun(args,_)]) ->
					{e with eexpr = TNew(c,tl,check_call_params gen el args)}
				| _ -> Type.map_expr gen.map e
			end
		| TArrayDecl el ->
			begin match follow e.etype with
				| TInst({cl_path=[],"Array"},[t]) -> {e with eexpr = TArrayDecl(List.map (fun e -> check gen (gen.map e) t) el)}
				| _ -> Type.map_expr gen.map e
			end
		| TObjectDecl fl ->
			begin match follow e.etype with
				| TAnon an ->
					let fl = List.map (fun (n,e) ->
						let t = (PMap.find n an.a_fields).cf_type in
						n,check gen (gen.map e) t
					) fl in
					{ e with eexpr = TObjectDecl fl }
				| _ -> Type.map_expr gen.map e
			end
		| TReturn (Some e1) ->
			begin match !fstack with
				| tf :: _ -> { e with eexpr = TReturn (Some (check gen (gen.map e1) tf.tf_type))}
				| _ -> assert false
			end
		| TCast (e1,None) ->
			if e1.etype != e.etype then
				{e with eexpr = TCast(check gen (gen.map e1) e.etype,None)}
			else
				{e with eexpr = TCast(gen.map e1,None)}
		| TSwitch(e1,cases,def) ->
			let cases = List.map (fun (el,e) -> List.map (fun e -> check gen (gen.map e) e1.etype) el,gen.map e) cases in
			{ e with eexpr = TSwitch(e1,cases,match def with None -> None | Some e -> Some (gen.map e))}
		| TFunction tf ->
			fstack := tf :: !fstack;
			let etf = {e with eexpr = TFunction({tf with tf_expr = gen.map tf.tf_expr})} in
			fstack := List.tl !fstack;
			etf
		| TThrow e1 ->
			{ e with eexpr = TThrow (check gen e1 e1.etype) }
(* 		| TField(e1,(FInstance(_) as fa)) when not !is_call_expr ->
			let e1 = gen.map e1 in
			Expr.mk_cast {e with eexpr = TField(e1,fa)} e.etype *)
		| _ ->
			Type.map_expr gen.map e

end


(*
	- wraps String literals in String
	- translates String OpAdd to String.concat
	- translates String == String to String.equals
*)
module StringHandler = struct
	let is_string t = match follow t with
		| TInst({cl_path = [],"String"},_) -> true
		| _ -> false

	let filter gen e =
		match e.eexpr with
		(* always wrap String literal *)
		| TCall({eexpr = TField(_,FStatic({cl_path=[],"String"},{cf_name = "raw"}))},[{eexpr = TConst(TString s)} as e]) ->
			e
		| (TConst (TString s) | TNew({cl_path=[],"String"},[],[{eexpr = TConst(TString s)}])) ->
			Wrap.wrap_string gen.gcon.hxc (mk (TConst (TString s)) e.etype e.epos)
		| TCall({eexpr = TField(_,FStatic({cl_path=[],"Std"},{cf_name = "string"}))},[e1]) ->
			begin match follow e1.etype with
				| TAbstract({a_path = ["c"],"ConstPointer"},[TAbstract({a_path=[],"hx_char"},_)]) ->
					Wrap.wrap_string gen.gcon.hxc e1
				| _ ->
					e
			end
		| TBinop((OpEq | OpNotEq) as op,e1,e2) when is_string e1.etype ->
			Expr.mk_binop op
				(Expr.mk_static_call_2 gen.gcon.hxc.c_string "equals" [gen.map e1; gen.map e2] e1.epos)
				(mk (TConst (TBool true)) gen.gcom.basic.tbool e1.epos)
				e.etype
				e.epos
		| TBinop(OpAdd,e1,e2) when is_string e1.etype ->
			Expr.mk_static_call_2 gen.gcon.hxc.c_string "concat" [gen.map e1; gen.map e2] e1.epos
		| TBinop(OpAssignOp(OpAdd),e1,e2) when is_string e1.etype ->
			(* TODO: we have to cache e1 in a temp var and handle the assignment correctly *)
			Expr.mk_binop
				OpAssign
				e1
				(Expr.mk_static_call_2 gen.gcon.hxc.c_string "concat" [gen.map e1; gen.map e2] e1.epos)
				e1.etype
				e.epos
		| _ ->
			Type.map_expr gen.map e
end

(*
	- converts TPatMatch to TSwitch
	- converts TSwitch on String to an if/else chain
*)
module SwitchHandler = struct
	let filter gen e =
		match e.eexpr with
		| TPatMatch dt ->
			let fl = gen.gcon.num_labels in
			gen.gcon.num_labels <- gen.gcon.num_labels + (Array.length dt.dt_dt_lookup) + 1;
			let i_last = Array.length dt.dt_dt_lookup in
			let mk_label_expr i = mk (TConst (TInt (Int32.of_int (i + fl)))) gen.gcom.basic.tint e.epos in
			let mk_label_meta i =
				let elabel = mk_label_expr i in
				Expr.add_meta (Meta.Custom ":label") elabel
			in
			let mk_goto_meta i =
				let elabel = mk_label_expr i in
				Expr.add_meta (Meta.Custom ":goto") elabel
			in
			let check_var_name v =
				if v.v_name.[0] = '`' then v.v_name <- "_" ^ (String.sub v.v_name 1 (String.length v.v_name - 1));
			in
			let rec mk_dt dt =
				match dt with
				| DTExpr e ->
					let egoto = mk_goto_meta i_last in
					Codegen.concat e egoto
				| DTGuard(e1,dt,dto) ->
					let ethen = mk_dt dt in
					let eelse = match dto with None -> None | Some dt -> Some (mk_dt dt) in
					mk (TIf(Codegen.mk_parent e1,ethen,eelse)) ethen.etype (punion e1.epos ethen.epos)
				| DTBind(vl,dt) ->
					let vl = List.map (fun ((v,_),e) ->
						check_var_name v;
						v,Some e
					) vl in
					let evars = mk (TVars vl) gen.gcom.basic.tvoid e.epos in
					Codegen.concat evars (mk_dt dt)
				| DTGoto i ->
					mk_goto_meta i
				| DTSwitch(e1,cl,dto) ->
					let cl = List.map (fun (e,dt) -> [e],mk_dt dt) cl in
					let edef = match dto with None -> None | Some dt -> Some (mk_dt dt) in
					mk (TSwitch(e1,cl,edef)) t_dynamic e.epos
			in
			let el,i = Array.fold_left (fun (acc,i) dt ->
				let elabel = mk_label_meta i in
				let edt = mk_dt dt in
				(Codegen.concat elabel edt) :: acc,i + 1
			) ([],0) dt.dt_dt_lookup in
			let e = gen.map (Expr.mk_block gen.gcom e.epos el) in
			let e = Expr.add_meta (Meta.Custom ":patternMatching") e in
			List.iter (fun (v,_) -> check_var_name v) dt.dt_var_init;
			let einit = mk (TVars dt.dt_var_init) gen.gcom.basic.tvoid e.epos in
			let elabel = mk_label_meta i in
			let e1 = Codegen.concat einit (Codegen.concat e elabel) in
			if dt.dt_first = i - 1 then
				e1
			else
				Codegen.concat (mk_goto_meta dt.dt_first) e1
		| TSwitch(e1,cases,def) when StringHandler.is_string e1.etype ->
			let length_map = Hashtbl.create 0 in
			List.iter (fun (el,e) ->
				List.iter (fun es ->
					match es.eexpr with
					| TConst (TString s) ->
						let l = String.length s in
						let sl = try
							Hashtbl.find length_map l
						with Not_found ->
							let sl = ref [] in
							Hashtbl.replace length_map l sl;
							sl
						in
						sl := ([es],e) :: !sl;
					| _ ->
						()
				) el
			) cases;
			let mk_eq e1 e2 = mk (TBinop(OpEq,e1,e2)) gen.gcon.com.basic.tbool (punion e1.epos e2.epos) in
			let mk_or e1 e2 = mk (TBinop(OpOr,e1,e2)) gen.gcon.com.basic.tbool (punion e1.epos e2.epos) in
			let mk_if (el,e) eo =
				let eif = List.fold_left (fun eacc e -> mk_or eacc (mk_eq e1 e)) (mk_eq e1 (List.hd el)) (List.tl el) in
				mk (TIf(Codegen.mk_parent eif,e,eo)) e.etype e.epos
			in
			let cases = Hashtbl.fold (fun i el acc ->
				let eint = mk (TConst (TInt (Int32.of_int i))) gen.gcom.basic.tint e.epos in
				let fs = match List.fold_left (fun eacc ec -> Some (mk_if ec eacc)) def !el with Some e -> e | None -> assert false in
				([eint],fs) :: acc
			) length_map [] in
 			let c_string = match gen.gcom.basic.tstring with TInst(c,_) -> c | _ -> assert false in
			let cf_length = PMap.find "length" c_string.cl_fields in
			let ef = mk (TField(e1,FInstance(c_string,cf_length))) gen.gcom.basic.tint e.epos in
			let e = mk (TSwitch(Codegen.mk_parent ef,cases,def)) t_dynamic e.epos in
			gen.map e
		| _ ->
				Type.map_expr gen.map e
end


(*
	This filter turns all non-top TFunction nodes into class fields and creates a c.Closure object
	in their place.

	It also handles calls to closures, i.e. local variables and Var class fields.
*)
module ClosureHandler = struct
	let fstack = ref []

	let ctx_name = mk_runtime_prefix "ctx"

	let mk_closure_field gen tf ethis p =
		let locals = ref PMap.empty in
		let unknown = ref PMap.empty in
		let save_locals () =
			let old = !locals in
			fun () -> locals := old
		in
		let add_local v = if not (PMap.mem v.v_name !locals) then locals := PMap.add v.v_name v !locals in
		let add_unknown v = if not (PMap.mem v.v_name !unknown) then unknown := PMap.add v.v_name v !unknown in
		List.iter (fun (v,_) -> add_local v) tf.tf_args;
		let v_this = alloc_var "this" (match ethis with Some e -> e.etype | _ -> mk_mono()) in
		let t_ctx = mk_mono() in
		let v_ctx = alloc_var ctx_name t_ctx in
		let e_ctx = mk (TLocal v_ctx) v_ctx.v_type p in
		let mk_ctx_field v =
			let ef = mk (TField(e_ctx,FDynamic v.v_name)) v.v_type p in
			Expr.mk_cast ef v.v_type
		in
		let rec loop e = match e.eexpr with
			| TVars vl ->
				let vl = List.map (fun (v,eo) ->
					add_local v;
					v,match eo with None -> None | Some e -> Some (loop e)
				) vl in
				{ e with eexpr = TVars vl }
			| TLocal v ->
				if not (PMap.mem v.v_name !locals) then begin
					add_unknown v;
					mk_ctx_field v;
				end else
					e
			| TFunction tf ->
				let save = save_locals() in
				List.iter (fun (v,_) -> add_local v) tf.tf_args;
				let e = { e with eexpr = TFunction { tf with tf_expr = loop tf.tf_expr } } in
				save();
				e
			| TConst TThis ->
				if not (PMap.mem v_this.v_name !locals) then add_unknown v_this;
				mk_ctx_field v_this
			| _ ->
				Type.map_expr loop e
		in
		let e = loop tf.tf_expr in
		let name = alloc_temp_func gen.gcon in
		let vars,fields = PMap.fold (fun v (vars,fields) ->
			let e = match v.v_name,ethis with
				| "this",Some e -> e
				| _ -> mk (TLocal v) v.v_type p
			in
			(v :: vars),((v.v_name,e) :: fields)
		) !unknown ([],[]) in
		let eobj = Expr.mk_obj_decl fields p in
		Type.unify eobj.etype t_ctx;
		let t = TFun((ctx_name,false,eobj.etype) :: List.map (fun (v,_) -> v.v_name,false,v.v_type) tf.tf_args,tf.tf_type) in
		let cf = Expr.mk_class_field name t true p (Method MethNormal) [] in
		let tf = {
			tf_args = (v_ctx,None) :: tf.tf_args;
			tf_type = tf.tf_type;
			tf_expr = e;
		} in
		cf.cf_expr <- Some (mk (TFunction tf) e.etype e.epos);
		cf,eobj

	let add_closure_field gen c tf ethis p =
		let cf,e_init = mk_closure_field gen tf ethis p in
		gen.add_field c cf true;
		let e_field = mk (TField(e_init,FStatic(c,cf))) cf.cf_type p in
		Wrap.wrap_function gen.gcon.hxc e_init e_field

	let is_call_expr = ref false
	let is_extern = ref false

	let is_native_function_pointer t =
		match t with
			| TAbstract( { a_path = ["c"],"FunctionPointer" }, _ ) -> true
			| _ -> false

	let rec is_closure_expr e =
		not (is_native_function_pointer e.etype) && match e.eexpr with
			| TMeta(_,e1) | TParenthesis(e1) | TCast(e1,None) ->
				is_closure_expr e1
			| TField(_,(FStatic(_,cf) | FInstance(_,cf))) ->
				begin match cf.cf_kind with
					| Var _ -> true
					| _ -> false
				end
			| TField(_,FEnum _) ->
				false
			| TConst TSuper ->
				false
			| _ ->
				true

	let filter gen e =
		match e.eexpr with
		| TFunction tf ->
			fstack := tf :: !fstack;
			let e1 = match !fstack with
				| _ :: [] when (match gen.gfield.cf_kind with Method _ -> true | Var _ -> false) ->
					{e with eexpr = TFunction({tf with tf_expr = gen.map tf.tf_expr})}
				| _ ->
					add_closure_field gen gen.gclass tf None e.epos
			in
			fstack := List.tl !fstack;
			e1
		| _ when is_native_function_pointer e.etype ->
			e
		| TCall(e1,el) ->
			let old = !is_call_expr,!is_extern in
			is_call_expr := true;
			is_extern := (match e1.eexpr with TField(_,FStatic({cl_extern = true},_)) -> true | _ -> false);
			let e1 = gen.map e1 in
			is_call_expr := fst old;
			let el = List.map gen.map el in
			let e = if not !is_extern && is_closure_expr e1 then begin
				let args,r = match follow e1.etype with TFun(args,r) -> args,r | _ -> assert false in
				let mk_cast e = mk (TCast(e,None)) (gen.gcon.hxc.t_func_pointer e.etype) e.epos in
				let efunc = mk (TField(e1,FDynamic "_func")) (TFun(args,r)) e.epos in
				let efunc2 = {efunc with etype = TFun(("_ctx",false,t_dynamic) :: args,r)} in
				let ethis = mk (TField(e1,FDynamic "_this")) t_dynamic e.epos in
				let eif = Codegen.mk_parent (Expr.mk_binop OpNotEq ethis (mk (TConst TNull) (mk_mono()) e.epos) gen.gcom.basic.tbool e.epos) in
				let ethen = mk (TCall(mk_cast efunc2,ethis :: el)) e.etype e.epos in
				let eelse = mk (TCall(mk_cast efunc,el)) e.etype e.epos in
				let e = mk (TIf(eif,ethen,Some eelse)) e.etype e.epos in
				Expr.mk_cast e r
			end else
				{e with eexpr = TCall(e1,el)}
			in
			is_extern := snd old;
			e
		| TField(_,FStatic(c,({cf_kind = Method m} as cf))) when not !is_call_expr && not !is_extern ->
			Wrap.wrap_static_function gen.gcon.hxc (Expr.mk_static_field c cf e.epos)
		| TField(e1,FClosure(Some c,{cf_expr = Some {eexpr = TFunction tf}})) ->
			add_closure_field gen c tf (Some e1) e.epos
		| _ ->
			Type.map_expr gen.map e
end

(*
	- translates a[b] to a.__get(b) if such a method exists
	- translates a[b] = c to a.__set(b, c) if such a method exists
	- finds specialization calls and applies their suffix
*)
module ArrayHandler = struct

	let get_type_size hxc tp = match tp with
	| TAbstract ( { a_path =[], "Int" } ,_ )
	| TAbstract ( { a_path =[], ("hx_int32" | "hx_uint32") } ,_ ) -> "32",(fun e -> e)
	| TAbstract ( { a_path =[], ("hx_int16" | "hx_uint16") } ,_ ) -> "16",(fun e -> e)
	| TAbstract ( { a_path =[], ("hx_int8" | "hx_uint8" | "hc_char" | "hx_uchar") } ,_ ) -> "8",(fun e -> e)
	| TAbstract ( { a_path =["c"], ("Int64" | "UInt64") } ,_ )
	| TAbstract ( {a_path = ["c"], "Pointer"}, _ ) -> "64",(fun e -> Expr.mk_cast e (hxc.t_int64 e.etype))
	(* FIXME: should we include ConstSizeArray here? *)
	| _ -> "64",(fun e -> Expr.mk_cast e (hxc.t_int64 e.etype))

	let rec mk_specialization_call c n suffix ethis el p =
		let name = if suffix = "" then n else n ^ "_" ^ suffix in
		begin try
			match ethis with
			| None ->
				let cf = PMap.find name c.cl_statics in
				Expr.mk_static_call c cf el p
			| Some (e,tl) ->
				let cf = PMap.find name c.cl_fields in
				let ef = mk (TField(e,FInstance(c,cf))) (apply_params c.cl_types tl cf.cf_type) p in
				mk (TCall(ef,el)) (match follow ef.etype with TFun(_,r) -> r | _ -> assert false) p
		with Not_found when suffix <> "" ->
			mk_specialization_call c n "" ethis el p
		end

	let filter gen e =
		match e.eexpr with
		| TArray(e1, e2) ->
			begin try begin match follow e1.etype with
				| TAbstract({a_path=["c"], "ConstSizeArray"},[t;_])
				| TAbstract({a_path=["c"], "Pointer"},[t]) ->
					{e with eexpr = TArray(gen.map e1, gen.map e2)}
				| TInst(c,[tp]) ->
					let suffix,cast = get_type_size gen.gcon.hxc (follow tp) in
					Expr.mk_cast (mk_specialization_call c "__get" suffix (Some(gen.map e1,[tp])) [gen.map e2] e.epos) tp
				| _ ->
					raise Not_found
			end with Not_found ->
				Expr.mk_cast (Type.map_expr gen.map e) e.etype
			end
		| TBinop( (Ast.OpAssign | Ast.OpAssignOp _ ), {eexpr = TArray(e1,e2)}, ev) ->
			(* if op <> Ast.OpAssign then assert false; FIXME: this should be handled in an earlier stage (gencommon, anyone?) *)
			begin try begin match follow e1.etype with
				| TInst(c,[tp]) ->
					let suffix,cast = get_type_size gen.gcon.hxc (follow tp) in
					mk_specialization_call c "__set" suffix (Some(e1,[tp])) [gen.map e2; cast (gen.map ev)] e.epos
				| _ ->
					raise Not_found
			end with Not_found ->
				Type.map_expr gen.map e
			end
		| TCall( ({eexpr = (TField (ethis,FInstance(c,({cf_name = cfname })))) }) ,el) ->
			begin try begin match follow ethis.etype with
				| TInst({cl_path = [],"Array"},[tp]) ->
					let suffix,cast = get_type_size gen.gcon.hxc (follow tp) in
					Expr.mk_cast (mk_specialization_call c cfname suffix (Some(ethis,[tp])) (List.map gen.map el) e.epos) e.etype
				| _ ->
					raise Not_found
			end with Not_found ->
				Type.map_expr gen.map e
			end
		| _ ->
			Type.map_expr gen.map e
end


(*
	- TTry is replaced with a TSwitch and uses setjmp
	- TThrow is replaced with a call to longjmp
	- TFor is replaced with TWhile
	- TArrayDecl introduces an init function which is TCalled
*)
module ExprTransformation = struct

	let mk_array_decl gen el t p =
		let tparam = match follow t with
			| TInst(_,[t]) -> t
			| _ -> assert false
		in
		let c_array = gen.gcon.hxc.c_array in
		let v = alloc_var "arr" (TInst(c_array,[tparam])) in
		let eloc = mk (TLocal v) v.v_type p in
		let eret = mk (TReturn (Some (eloc))) t_dynamic p in
		let (vars,einit,arity) = List.fold_left (fun (vl,el,i) e ->
			let v = alloc_var ("v" ^ (string_of_int i)) tparam in
			let e = Expr.mk_binop OpAssign (mk (TArray(eloc,Expr.mk_int gen.gcom i p)) tparam p) (mk (TLocal v) v.v_type p) tparam p in
			(v :: vl,e :: el,i + 1)
		) ([],[eret],0) el in
		let vars = List.rev vars in
		let suffix,_ = ArrayHandler.get_type_size gen.gcon.hxc tparam in
		let enew = ArrayHandler.mk_specialization_call c_array "__new" suffix  None [Expr.mk_int gen.gcon.com arity p] p in
		let evar = mk (TVars [v,Some enew]) gen.gcom.basic.tvoid p in
		let e = mk (TBlock (evar :: einit)) t p in
		let tf = {
			tf_args = List.map (fun v -> v,None) vars;
			tf_type = t;
			tf_expr = e;
		} in
		let name = alloc_temp_func gen.gcon in
		let tfun = TFun (List.map (fun v -> v.v_name,false,v.v_type) vars,t) in
		let cf = Expr.mk_class_field name tfun true p (Method MethNormal) [] in
		let efun = mk (TFunction tf) tfun p in
		cf.cf_expr <- Some efun;

		gen.add_field gen.gclass cf true;
		Expr.mk_static_call gen.gclass cf el p

	let filter gen e =
		match e.eexpr with
		| TTry (e1,cl) ->
			let p = e.epos in
			let hxc = gen.gcon.hxc in
			let epush = Expr.mk_static_call_2 hxc.c_exception "push" [] p in
			let esubj = Codegen.mk_parent (Expr.mk_static_call_2 hxc.c_csetjmp "setjmp" [Expr.mk_deref gen.gcon.hxc p epush] p) in
			let epop = Expr.mk_static_call_2 hxc.c_exception "pop" [] p in
			let loc = gen.declare_temp (hxc.t_pointer hxc.t_jmp_buf) None in
			let epopassign = mk (TVars [loc,Some epop]) gen.gcon.com.basic.tvoid p in
			let ec1,found = Expr.insert_expr (gen.map e1) true (fun e ->
				match e.eexpr with
				| TReturn _ | TBreak _ | TContinue -> Some epop
				| _ -> None
			) in
			let ec1 = if found then ec1 else Codegen.concat ec1 epop in
			let c1 = [Expr.mk_int gen.gcom 0 e.epos],ec1 in
			let def = ref None in
			let cl = c1 :: (ExtList.List.filter_map (fun (v,e) ->
				let evar = mk (TVars [v,Some (Expr.mk_static_field_2 hxc.c_exception "thrownObject" p)]) gen.gcon.com.basic.tvoid p in
				let e = Codegen.concat evar (Codegen.concat epopassign (gen.map e)) in
				if v.v_type == t_dynamic then begin
					def := Some e;
					None;
				end else
					Some ([Expr.mk_int gen.gcom (get_type_id gen.gcon v.v_type) e.epos],e)
			) cl) in
			mk (TSwitch(esubj,cl,!def)) e.etype e.epos
		| TThrow e1 ->
			let p = e.epos in
			let eassign = Codegen.binop OpAssign (Expr.mk_static_field_2 gen.gcon.hxc.c_exception "thrownObject" p) e1 e1.etype e1.epos in
			let epeek = Expr.mk_static_call_2 gen.gcon.hxc.c_exception "peek" [] p in
			let el = [Expr.mk_deref gen.gcon.hxc p epeek;Expr.mk_int gen.gcom (get_type_id gen.gcon e1.etype) p] in
			let ejmp = Expr.mk_static_call_2 gen.gcon.hxc.c_csetjmp "longjmp" el p in
			Codegen.concat eassign ejmp
		| TArrayDecl [] ->
			let c,t = match follow (gen.gcon.com.basic.tarray (mk_mono())) with
				| TInst(c,[t]) -> c,t
				| _ -> assert false
			in
			mk (TNew(c,[t],[])) gen.gcon.com.basic.tvoid e.epos
		| TArrayDecl el ->
			mk_array_decl gen (List.map gen.map el) e.etype e.epos
		| _ ->
			Type.map_expr gen.map e

end

(*
	- translates TFor to TWhile
*)
module ExprTransformation2 = struct

	let filter gen e =
		match e.eexpr with
		| TFor(v,e1,e2) ->
			let e1 = gen.map e1 in
			let vtemp = gen.declare_temp e1.etype None in
			gen.declare_var (v,None);
			let ev = Expr.mk_local vtemp e1.epos in
			let ehasnext = mk (TField(ev,quick_field e1.etype "hasNext")) (tfun [] gen.gcon.com.basic.tbool) e1.epos in
			let ehasnext = mk (TCall(ehasnext,[])) ehasnext.etype ehasnext.epos in
			let enext = mk (TField(ev,quick_field e1.etype "next")) (tfun [] v.v_type) e1.epos in
			let enext = mk (TCall(enext,[])) v.v_type e1.epos in
			let eassign = Expr.mk_binop OpAssign (Expr.mk_local v e.epos) enext v.v_type e.epos in
			let ebody = Codegen.concat eassign (gen.map e2) in
			mk (TBlock [
				mk (TVars [vtemp,Some e1]) gen.gcom.basic.tvoid e1.epos;
				mk (TWhile((mk (TParenthesis ehasnext) ehasnext.etype ehasnext.epos),ebody,NormalWhile)) gen.gcom.basic.tvoid e1.epos;
			]) gen.gcom.basic.tvoid e.epos
		| _ ->
			Type.map_expr gen.map e
end


(* Output and context *)

let spr ctx s = Buffer.add_string ctx.buf s
let print ctx = Printf.kprintf (fun s -> Buffer.add_string ctx.buf s)

let newline ctx =
	match Buffer.nth ctx.buf (Buffer.length ctx.buf - 1) with
	| '{' | ':' | ' '
	| '}' when Buffer.length ctx.buf > 1 && Buffer.nth ctx.buf (Buffer.length ctx.buf - 2) != '"' ->
		print ctx "\n%s" ctx.tabs
	| '\t' -> ()
	| _ ->
		print ctx ";\n%s" ctx.tabs

let rec concat ctx s f = function
	| [] -> ()
	| [x] -> f x
	| x :: l ->
		f x;
		spr ctx s;
		concat ctx s f l

let open_block ctx =
	let oldt = ctx.tabs in
	ctx.tabs <- "\t" ^ ctx.tabs;
	(fun() -> ctx.tabs <- oldt)

let mk_type_context con path =
	let rec create acc = function
		| [] -> ()
		| d :: l ->
			let pdir = String.concat "/" (List.rev (d :: acc)) in
			if not (Sys.file_exists pdir) then Unix.mkdir pdir 0o755;
			create (d :: acc) l
	in
	let dir = con.com.file :: fst path in
	create [] dir;
	let buf_c = Buffer.create (1 lsl 14) in
	let buf_h = Buffer.create (1 lsl 14) in
	{
		con = con;
		file_path_no_ext = String.concat "/" dir ^ "/" ^ (snd path);
		buf = buf_h;
		buf_c = buf_c;
		buf_h = buf_h;
		tabs = "";
		type_path = path;
		fctx = {
			field = null_field;
			loop_stack = [];
			meta = [];
		};
		dependencies = PMap.empty;
	}

let path_to_file_path (pack,name) = match pack with [] -> name | _ -> String.concat "/" pack ^ "/" ^ name

let close_type_context ctx =
	let get_relative_path source target =
		let rec loop pl1 pl2 acc = match pl1,pl2 with
			| s1 :: pl1,[] ->
				loop pl1 [] (".." :: acc)
			| [],s2 :: pl2 ->
				loop [] pl2 (s2 :: acc)
			| s1 :: pl1,s2 :: pl2 ->
				if s1 = s2 then loop pl1 pl2 acc
				else (List.map (fun _ -> "..") (s1 :: pl1)) @ [s2] @ pl2
			| [],[] ->
				List.rev acc
		in
		loop (fst source) (fst target) []
	in
	ctx.con.generated_types <- ctx :: ctx.con.generated_types;
	let buf = Buffer.create (Buffer.length ctx.buf_h) in
	let spr = Buffer.add_string buf in
	let n = "_h" ^ path_to_name ctx.type_path in
	let relpath path = path_to_file_path ((get_relative_path ctx.type_path path),snd path) in
	spr (Printf.sprintf "#ifndef %s\n" n);
	spr (Printf.sprintf "#define %s\n" n);
	if ctx.type_path <> ([],"hxc") then spr (Printf.sprintf "#include \"%s.h\"\n" (relpath ([],"hxc")));

	PMap.iter (fun path dept ->
		let name = path_to_name path in
		match dept with
			| DCStd -> spr (Printf.sprintf "#include <%s.h>\n" (path_to_file_path path))
			| DFull -> spr (Printf.sprintf "#include \"%s.h\"\n" (relpath path))
			| DForward -> spr (Printf.sprintf "typedef struct %s %s;\n" name name);
	) ctx.dependencies;
	Buffer.add_buffer buf ctx.buf_h;
	spr "\n#endif";

	let write_if_changed filepath content =
		try
			let cur = Std.input_file ~bin:true filepath in
			if cur <> content then raise Not_found
		with Not_found | Sys_error _ ->
			let ch_h = open_out_bin filepath in
			print_endline ("Writing " ^ filepath);
			output_string ch_h content;
			close_out ch_h;
	in

	write_if_changed (ctx.file_path_no_ext ^ ".h") (Buffer.contents buf);

	let sc = Buffer.contents ctx.buf_c in
	if String.length sc > 0 then begin
		let buf = Buffer.create (Buffer.length ctx.buf_c) in
		Buffer.add_string buf ("#include \"" ^ (snd ctx.type_path) ^ ".h\"\n");
		PMap.iter (fun path dept ->
			match dept with
			| DFull | DForward ->
				Buffer.add_string buf (Printf.sprintf "#include \"%s.h\"\n" (relpath path))
			| _ -> ()
		) ctx.dependencies;
		Buffer.add_string buf sc;
		write_if_changed (ctx.file_path_no_ext ^ ".c") (Buffer.contents buf);
	end


(* Dependency handling *)

let parse_include com s p =
	if s.[0] = '<' then begin
		if s.[String.length s - 1] <> '>' then com.error "Invalid include directive" p;
		(* take off trailing .h because it will be added back later *)
		let i = if String.length s > 4 && s.[String.length s - 2] = 'h' && s.[String.length s - 3] = '.' then
			String.length s - 4
		else
			String.length s - 2
		in
		([],String.sub s 1 i),DCStd
	end else
		([],s),DForward

let add_dependency ctx dept path =
	if path <> ctx.type_path then ctx.dependencies <- PMap.add path dept ctx.dependencies

let check_include_meta ctx meta =
	try
		let _,el,p = get_meta Meta.Include meta in
		List.iter (fun e -> match fst e with
			| EConst(String s) when String.length s > 0 ->
				let path,dept = parse_include ctx.con.com s p in
				add_dependency ctx dept path
			| _ ->
				()
		) el;
		true
	with Not_found ->
		false

let add_class_dependency ctx c =
	match c.cl_kind with
	| KTypeParameter _ -> ()
	| _ ->
		if not (check_include_meta ctx c.cl_meta) && not c.cl_extern then
			add_dependency ctx (if Meta.has Meta.Struct c.cl_meta then DFull else DForward) c.cl_path

let add_enum_dependency ctx en =
	if not (check_include_meta ctx en.e_meta) && not en.e_extern then
		add_dependency ctx (if Meta.has Meta.Struct en.e_meta || Meta.has Meta.FlatEnum en.e_meta then DFull else DForward) en.e_path

let add_abstract_dependency ctx a =
	if not (check_include_meta ctx a.a_meta) then
		add_dependency ctx (if Meta.has Meta.Struct a.a_meta then DFull else DForward) a.a_path

let add_type_dependency ctx t = match follow t with
	| TInst(c,_) ->
		add_class_dependency ctx c
	| TEnum(en,_) ->
		add_enum_dependency ctx en
	| TAnon an ->
		add_dependency ctx DFull (["c"],ctx.con.get_anon_signature an.a_fields);
	| TAbstract(a,_) ->
		add_abstract_dependency ctx a
	| TDynamic _ ->
		add_dependency ctx DForward ([],"Dynamic")
	| _ ->
		(* TODO: that doesn't seem quite right *)
		add_dependency ctx DForward ([],"Dynamic")


module VTableHandler = struct

	(*
	let fold_map f c xs =
		let c, ys = List.fold_left ( fun (acc,ys) x ->
			let acc, y  = f acc x in acc, (y :: ys)
		) (c,[]) xs in
		c, List.rev ys
	*)

	type vt_t = (string, tclass_field * int * tclass) PMap.t

	type maps = {
		mutable next    : int;
		mutable cids    : ( string, int ) PMap.t;
		mutable count   : ( int, int ) PMap.t;
		mutable types   : ( int, tclass ) PMap.t;
		mutable vtables : ( int, vt_t ) PMap.t;
	}

	let insert_or_inc con m id  =
		if PMap.exists id m then PMap.add id ((PMap.find id m) + 1) m else (PMap.add id 0 m)

	let get_class_id m c =
		let s  = String.concat ""  ((snd c.cl_path) :: (fst c.cl_path)) in
		let id = m.next in
		if PMap.exists s m.cids
			then (PMap.find s m.cids, m)
			else (	m.cids <- PMap.add s id m.cids; m.next <- id +1; (id,m) )

	(*
	let filterin f i xs =
		let rec loop i xs acc = match xs with
		| x :: xs -> if f(x) then loop (i+1) xs ((i,x) :: acc) else loop i xs acc
		| [] -> (i,acc)
		in loop i xs [] *)

	let get_methods c = List.filter ( fun cf -> match cf.cf_kind with
			| Method (MethNormal) -> true
			| _ -> false ) c.cl_ordered_fields

	let reverse_collect c =
		let next  = ref 0 in
		let idmap = ref PMap.empty in
		let get_id n =
			if PMap.exists n !idmap then
				PMap.find n !idmap
			else
				let id = !next in
				next := !next + 1;
				idmap := PMap.add n id !idmap;
				id
		in
		let rev_chain c =
			let rec loop c acc = match c.cl_super with
			| Some (c,_) ->  loop c ( c :: acc)
			| _ -> acc
			in (loop c [c])
		in
		let add_meta meta meta_item el p =
				if (Meta.has (Meta.Custom meta_item) meta) then meta
				else (Meta.Custom meta_item, el, p) :: meta
		in
		let rec collect sc super acc xs = match xs with
		| []        ->  (sc,super) :: acc
		| c :: tail ->
			let methods = (get_methods c) in
			c.cl_meta <- add_meta c.cl_meta ":hasvtable" [] null_pos;
			let mm = List.fold_left ( fun  m cf ->
				let vidx = (get_id cf.cf_name) in
					( cf.cf_meta <- add_meta cf.cf_meta ":overridden" [EConst(Int (string_of_int vidx)),cf.cf_pos] cf.cf_pos;
					PMap.add cf.cf_name ( cf, vidx ,c) m )
				) PMap.empty methods
			in
			let mm = PMap.foldi ( fun k (scf,vidx,sc) mm ->
				if PMap.mem k mm then mm
				else PMap.add k (scf,vidx,sc) mm
			) super mm
			in
			collect c mm ( (sc,super) :: acc) tail
		in
		let ichain = collect null_class PMap.empty [] (rev_chain c)
		in  ichain (*print_endline (string_of_int (List.length ichain))*)

	let p_ichain xs = List.iter (fun (c,m) ->
		(   print_endline ( "---" ^ (snd c.cl_path));
			(PMap.iter
				(fun _ (cf,midx,c) -> (Printf.printf "class: %s func: %s idx:%d\n" (snd c.cl_path) cf.cf_name midx) )
			m)
		)
	) xs

	let get_class_name cf = match cf.cf_type with
	| TInst (c,_) -> snd c.cl_path
	| _ -> assert false


	let p_methods c = (
		List.iter ( fun cf -> match cf.cf_kind with
			| Method (MethNormal) ->
				print_endline ( " methnormal: " ^ cf.cf_name )
			| _ -> ()
		) c.cl_ordered_fields;
		List.iter ( fun cf -> match cf.cf_kind with
			| Method (MethNormal) ->
				print_endline ( " override: " ^ cf.cf_name  )
			| _ -> ()
		) c.cl_overrides )

	let get_chains con tps =

		let m = List.fold_left ( fun m tp -> match tp with
			| TClassDecl c -> ( match c.cl_super with
				| Some (c1,_) ->
					let (id,m) =  (get_class_id m c)  in
					let (id1,m) =  (get_class_id m c1) in
						m.types <- PMap.add id c m.types;
						m.types <- PMap.add id1 c1 m.types;
						m.count <- (insert_or_inc con m.count id);
						m.count <- (insert_or_inc con m.count id1);
						m
				| None -> m )
			| _ -> m ) { count   = PMap.empty;
			             types   = PMap.empty;
						 cids    = PMap.empty;
						 vtables = PMap.empty;
						 next    = 0} tps in

		(* let _ = Analyzer.run_analyzer tps in *)

		let add_vtable con c vtable =
			(* helpers *)
			let clib, cstdlib = con.hxc.c_lib, con.hxc.c_cstdlib in
			let fname   = (mk_runtime_prefix "_vtable") in
			let c_vt    = con.hxc.c_vtable in
			(* let t_vt    = (TInst(c_vt,[])) in *)
			let t_int   = con.com.basic.tint in
			let t_voidp = con.hxc.t_pointer con.com.basic.tvoid in
			let t_vtfp  = con.hxc.t_func_pointer (Type.tfun [con.com.basic.tvoid] con.com.basic.tvoid) in
			let cf_vt = Type.mk_field fname (TInst(con.hxc.c_vtable,[])) null_pos in
			let mk_ccode s  =
				Expr.mk_static_call_2 con.hxc.c_lib "cCode" [mk (TConst (TString s)) con.com.basic.tstring null_pos] null_pos in
			let mk_field c ethis n p = try
				let cf = (PMap.find n c.cl_fields) in
				mk (TField (ethis,(FInstance (c,cf)))) cf.cf_type p
			with Not_found -> assert false
			in
			c.cl_statics <- PMap.add fname cf_vt c.cl_statics;
			c.cl_ordered_statics <- cf_vt :: c.cl_ordered_statics;

			(* 1. add global field for the vtable pointer *)
			let e_vt = Expr.mk_static_field c cf_vt null_pos in

			(* 2. add vtable initialization to cl_init *)

			let e_slot = mk_field c_vt e_vt "slots" null_pos in
			(* 2.1. fill vtable with function pointers*)
			let (mx,l_easgn) = PMap.fold ( fun (cf,vidx,c2) (mx,acc) ->
				let e_fp = Expr.mk_cast (Expr.mk_static_field c2 cf null_pos) t_vtfp in
				let esetidx = Expr.mk_binop OpAssign
					(mk (TArray(e_slot,(Expr.mk_int con.com vidx null_pos))) t_vtfp null_pos) e_fp t_vtfp null_pos in
				(max mx vidx, esetidx :: acc)
			) vtable (0,[]) in

			let sizeof t = Expr.mk_static_call clib con.hxc.cf_sizeof [(mk (TConst TNull) t null_pos)] null_pos in
			let vt_size = mx+1 in
			let e_vtsize = (Expr.mk_int con.com vt_size null_pos) in
			(* sizeof(vtable_t) + vt_size * sizeof(void ( * )())  *)
			(* 2.2 allocate vtable struct (after 2.1 because we have the vtable size now) *)
			let e_allocsize  =
				Expr.mk_binop OpAdd (mk_ccode "sizeof(c_VTable)") (
					Expr.mk_binop OpMult e_vtsize (sizeof t_vtfp) t_int null_pos
				) t_int null_pos in
			let e_alloc = Expr.mk_static_call_2 cstdlib "malloc" [e_allocsize] null_pos in
			let e_assign_ptr = (Expr.mk_binop OpAssign e_vt e_alloc t_voidp null_pos) in
			let e_block =  Expr.mk_block con.com null_pos (e_assign_ptr :: l_easgn) in
			c.cl_init <- ( match c.cl_init with
			| Some code -> Some (Codegen.concat e_block code)
			| None      -> Some e_block )

		in

		let eochains =
			PMap.foldi (fun  k v acc -> if v = 0 then (PMap.find k m.types) :: acc else acc) m.count [] in
			let gcid c =
				let (id,m) = get_class_id m c in id
			in
			let ifadd c v = if PMap.exists (gcid c) m.vtables then
								false
							else
								let pm = PMap.add (gcid c) v m.vtables in
								let _ = m.vtables <- pm in
								true
			in
			List.iter ( fun c -> (
				(*print_endline (  " end of chain: " ^ (snd c.cl_path)   );*)
				(*p_methods c;*)
				let ichain = (reverse_collect c) in
				(*p_ichain ichain;*)
				List.iter ( fun (c,m) -> if (ifadd c m) then  add_vtable con c m else () ) ichain
				)
			) eochains
end


(* Helper *)

let rec is_value_type t =
	match t with
	| TType({t_path=[],"Null"},[t]) ->
		false
	| TMono r ->
		begin match !r with
			| Some t -> is_value_type t
			| _ -> false
		end
	| TLazy f ->
		is_value_type (!f())
	| TType (t,tl) ->
		is_value_type (apply_params t.t_types tl t.t_type)
	| TAbstract({a_path=[],"Class"},_) ->
		false
	| TAbstract({ a_impl = None }, _) ->
		true
	| TInst(c,_) ->
		has_meta Meta.Struct c.cl_meta
	| TEnum(en,_) ->
		Meta.has Meta.FlatEnum en.e_meta
	| TAbstract(a,tl) ->
		if has_meta Meta.NotNull a.a_meta then
			true
		else
			is_value_type (Codegen.Abstract.get_underlying_type a tl)
	| _ ->
		false

let begin_loop ctx =
	ctx.fctx.loop_stack <- None :: ctx.fctx.loop_stack;
	fun () ->
		match ctx.fctx.loop_stack with
		| ls :: l ->
			begin match ls with
				| None -> ()
				| Some s ->
					newline ctx;
					print ctx "%s: {}" s
			end;
			ctx.fctx.loop_stack <- l;
		| _ ->
			assert false

let get_native_name meta =
	try begin
		match Meta.get Meta.Native meta with
			| _,[EConst (String s),_],_ -> Some s
			| _,_,_ -> None
	end with Not_found ->
		None

let full_field_name c cf =
	if Meta.has Meta.Plain cf.cf_meta then cf.cf_name
	else match get_native_name cf.cf_meta with
		| Some n -> n
		| None -> (path_to_name c.cl_path) ^ "_" ^ cf.cf_name

let full_enum_field_name en ef = (path_to_name en.e_path) ^ "_" ^ ef.ef_name

let get_typeref_name name =
	Printf.sprintf "%s_%s" name (mk_runtime_prefix "typeref")

let monofy_class c = TInst(c,List.map (fun _ -> mk_mono()) c.cl_types)

let keywords =
	let h = Hashtbl.create 0 in
	List.iter (fun s -> Hashtbl.add h s ()) [
		"auto";"break";"case";"char";"const";"continue";" default";"do";"double";
		"else";"enum";"extern";"float";"for";"goto";"if";"int";
		"long";"register";"return";"short";"signed";"sizeof";"static";"struct";
		"switch";"typedef";"union";"unsigned";"void";"volatile";"while";
	];
	h

let escape_name n =
	if Hashtbl.mem keywords n then mk_runtime_prefix n else n


(* Type signature *)

let rec s_type ctx t =
	if is_null t then
		s_type ctx (Wrap.mk_box_type t)
	else match follow t with
	| TAbstract({a_path = [],"Int"},[]) -> "int"
	| TAbstract({a_path = [],"Float"},[]) -> "double"
	| TAbstract({a_path = [],"Void"},[]) -> "void"
	| TAbstract({a_path = ["c"],"Pointer"},[t]) -> (match follow t with
		| TInst({cl_kind = KTypeParameter _},_) ->
			"char*" (* we will manipulate an array of type parameters like an array of bytes *)
		| _ -> s_type ctx t ^ "*")
	| TAbstract({a_path = ["c"],"ConstPointer"},[t]) -> "const " ^ (s_type ctx t) ^ "*"
	| TAbstract({a_path = ["c"],"Struct"},[t]) ->
		(match t with
		| TInst (c,_) ->
			add_dependency ctx DFull c.cl_path;
			path_to_name c.cl_path
		| _ -> assert false )
	| TAbstract({a_path = ["c"],"FunctionPointer"},[TFun(args,ret) as t]) ->
		add_type_dependency ctx (ctx.con.hxc.t_closure t);
		Printf.sprintf "%s (*)(%s)" (s_type ctx ret) (String.concat "," (List.map (fun (_,_,t) -> s_type ctx t) args))
	| TInst(({cl_path = ["c"],"TypeReference"} as c),_) ->
		add_class_dependency ctx c;
		"const " ^ (path_to_name c.cl_path) ^ "*"
	| TAbstract({a_path = [],"Bool"},[]) -> "int"
	| TAbstract( a, tps ) when Meta.has (Meta.Custom ":int") a.a_meta ->
		let (meta,el,epos) = Meta.get (Meta.Custom ":int") a.a_meta in
		(match el with
			| [(EConst (String s),_)] -> ( match s with
			| "int64" -> "hx_int64"
			| "int32" -> "hx_int32"
			| "int16" -> "hx_int16"
			| "int8"  -> "hx_int8"
			| "uint64" -> "hx_uint64"
			| "uint32" -> "hx_uint32"
			| "uint16" -> "hx_uint16"
			| "uint8" -> "hx_uint8"
			| _ -> s)
			| _ -> assert false;
	)
	| TInst({cl_kind = KTypeParameter _} as c,_) ->
		(* HACK HACK HACK HACK *)
		if c.cl_path = (["c";"TypeReference"],"T") then "const void*"
		else "void*"
	| TInst(c,_) ->
		let ptr = if is_value_type t then "" else "*" in
		add_class_dependency ctx c;
		(path_to_name c.cl_path) ^ ptr
	| TEnum(en,_) ->
		let ptr = if is_value_type t then "" else "*" in
		add_enum_dependency ctx en;
		(path_to_name en.e_path) ^ ptr
	| TAbstract(a,_) when Meta.has Meta.Native a.a_meta ->
		let ptr = if is_value_type t then "" else "*" in
		(path_to_name a.a_path) ^ ptr
	| TAnon a ->
		begin match !(a.a_status) with
		| Statics c -> "Class_" ^ (path_to_name c.cl_path) ^ "*"
		| EnumStatics en -> "Enum_" ^ (path_to_name en.e_path) ^ "*"
		| AbstractStatics a -> "Anon_" ^ (path_to_name a.a_path) ^ "*"
		| _ ->
			let signature = ctx.con.get_anon_signature a.a_fields in
			add_dependency ctx DFull (["c"],signature);
			"c_" ^ signature ^ "*"
		end
	| TFun(args,ret) ->
		let t = ctx.con.hxc.t_closure t in
		add_type_dependency ctx t;
		s_type ctx t
	| _ -> "void*"

let rec s_type_with_name ctx t n =
	match follow t with
	| TFun(args,ret) ->
		let t = ctx.con.hxc.t_closure t in
		add_type_dependency ctx t;
		s_type_with_name ctx t n
	| TAbstract({a_path = ["c"],"Pointer"},[t]) ->
		begin match follow t with
			| TInst({cl_kind = KTypeParameter _},_) -> "char* " ^ n (* TODO: ??? *)
			| _ -> (s_type_with_name ctx t ("*" ^ n))
		end
	| TAbstract({a_path = ["c"],"FunctionPointer"},[TFun(args,ret) as t]) ->
		add_type_dependency ctx (ctx.con.hxc.t_closure t);
		Printf.sprintf "%s (*%s)(%s)" (s_type ctx ret) (escape_name n) (String.concat "," (List.map (fun (_,_,t) -> s_type ctx t) args))
	| TAbstract({a_path = ["c"],"ConstSizeArray"},[t;const]) ->
		let size = match follow const with
			| TInst({ cl_path=[],name },_) when String.length name > 1 && String.get name 0 = 'I' ->
				String.sub name 1 (String.length name - 1)
			| _ ->
				"1"
		in
		(s_type_with_name ctx t ((escape_name n) ^ "["^ size ^"]"))
	| _ ->
		(s_type ctx t) ^ " " ^ (escape_name n)


(* Expr generation *)

let rec generate_call ctx e need_val e1 el = match e1.eexpr,el with
	| TField(_,FStatic({cl_path = ["c"],"Lib"}, cf)),(e1 :: el) ->
		begin match cf.cf_name with
		| "getAddress" ->
			spr ctx "&(";
			generate_expr ctx true e1;
			spr ctx ")"
		| "dereference" ->
			if not need_val then generate_expr ctx true e1
			else begin
				spr ctx "*(";
				generate_expr ctx true e1;
				spr ctx ")"
			end
		| "sizeof" ->
			(* get TypeReference's type *)
			let t = match follow e1.etype with
				| TInst({cl_path = ["c"],"TypeReference"},[t]) -> follow t
				| t -> t
			in
			print ctx "sizeof(%s)" (s_type ctx t);
		| "alloca" ->
			spr ctx "ALLOCA(";
			generate_expr ctx true e1;
			spr ctx ")"
		| "cCode" ->
			let code = match e1.eexpr with
				| TConst (TString s) -> s
				| TCast ({eexpr = TConst (TString s) },None) -> s
				| TCall({eexpr = TField(_,FStatic({cl_path = [],"String"},
					{cf_name = "ofPointerCopyNT"}))},
					[{eexpr = TConst (TString s)}]) -> s
				| _ ->
				let _ = print_endline (s_expr (Type.s_type (print_context())) e1 ) in
				assert false
			in
			spr ctx code;
		| _ ->
			ctx.con.com.error ("Unknown Lib function: " ^ cf.cf_name) e.epos
		end
	| TField(_,FStatic({cl_path = ["c"],"Lib"}, {cf_name="callMain"})),[] ->
		add_dependency ctx DFull (["c"],"Init");
		begin match ctx.con.com.main with
			| Some e -> generate_expr ctx false e
			| None -> ()
		end
	| TField(_,FStatic(c,({cf_name = name} as cf))),el when Meta.has Meta.Plain cf.cf_meta ->
		add_class_dependency ctx c;
		ignore(check_include_meta ctx c.cl_meta);
		print ctx "%s(" name;
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")";
	| TField(_,FStatic(c,cf)),el when Meta.has Meta.Native cf.cf_meta ->
		add_class_dependency ctx c;
		let name = match get_native_name cf.cf_meta with
			| Some s -> s
			| None -> ctx.con.com.error "String argument expected for @:native" e.epos; "_"
		in
		print ctx "%s(" name;
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")";
	| TField({eexpr = TConst TSuper} as e1, FInstance(c,cf)),el ->
		generate_expr ctx need_val (Expr.mk_static_call c cf (e1 :: el) e.epos)
	| TField(e1,FInstance(c,cf)),el when not (ClosureHandler.is_native_function_pointer cf.cf_type) ->
		add_class_dependency ctx c;
		let _ = if not (Meta.has (Meta.Custom ":overridden") cf.cf_meta) then
			spr ctx (full_field_name c cf)
		else
			let (meta,el,epos) = Meta.get (Meta.Custom ":overridden") cf.cf_meta in
			add_class_dependency ctx ctx.con.hxc.c_vtable;
			(match (meta,el,pos) with
			| (_,[EConst(Int idx),p],_) ->
				let oldbuf = ctx.buf in
				let buf = Buffer.create 0 in ctx.buf <- buf; generate_expr ctx true e1; (*TODO don't be lazy*)
				let s = Buffer.contents buf in
				let _ = ctx.buf <- oldbuf in
				let s = s ^ "->" ^ (mk_runtime_prefix "vtable") ^ "->slots["^idx^"]" in
				let ecode = Expr.mk_ccode ctx.con s null_pos in
				let t_this = match cf.cf_type with
				| TFun (ts, r) -> TFun ( ("",false,(e1.etype))  :: ts, r )
				| _ -> assert false
				in
				let cast = Expr.mk_cast ecode (ctx.con.hxc.t_func_pointer t_this) in
				generate_expr ctx true cast
			| _ -> assert false )
		in
		spr ctx "(";
		generate_expr ctx true e1;
		List.iter (fun e ->
			spr ctx ",";
			generate_expr ctx true e
		) el;
		spr ctx ")"
	| TField(_,FEnum(en,ef)),el ->
		print ctx "new_%s(" (full_enum_field_name en ef);
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")"
	| TConst (TSuper),el ->
		let csup = match follow e1.etype with
			| TInst(c,_) -> c
			| _ -> assert false
		in
		let n = (mk_runtime_prefix "initInstance") in
		let e = Expr.mk_static_call_2 csup n ((Expr.mk_local (alloc_var "this" e1.etype) e1.epos) :: el) e1.epos in
		generate_expr ctx false e
	| _ ->
		generate_expr ctx true e1;
		spr ctx "(";
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")"

and generate_constant ctx e = function
	| TString s ->
		print ctx "\"%s\"" s;
	| TInt i ->
		print ctx "%ld" i
	| TFloat s ->
		print ctx "%s" s
	| TNull ->
		spr ctx "NULL"
	| TSuper ->
		spr ctx "this"
	| TBool true ->
		spr ctx "1"
	| TBool false ->
		spr ctx "0"
	| TThis ->
		spr ctx "this"

and generate_expr ctx need_val e = match e.eexpr with
	| TConst c ->
		generate_constant ctx e c
	| TArray(e1, e2) ->
		generate_expr ctx need_val e1;
		spr ctx "[";
		generate_expr ctx true e2;
		spr ctx "]"
	| TBlock([])  ->
		if need_val then spr ctx "{ }"
	| TBlock el when need_val ->
		spr ctx "(";
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")"
	| TBlock(el) ->
		spr ctx "{";
		let b = open_block ctx in
		List.iter (fun e ->
			newline ctx;
			generate_expr ctx false e;
		) el;
		b();
		newline ctx;
		spr ctx "}";
	| TCall(e1,el) ->
		generate_call ctx e true e1 el
	| TTypeExpr (TClassDecl c) ->
		print ctx "&%s" (get_typeref_name (path_to_name c.cl_path));
	| TTypeExpr (TEnumDecl e) ->
		add_enum_dependency ctx e;
		spr ctx (path_to_name e.e_path);
	| TTypeExpr (TTypeDecl _ | TAbstractDecl _) ->
		(* shouldn't happen? *)
		assert false
	| TField(_,FStatic(c,cf)) ->
		add_class_dependency ctx c;
		spr ctx (full_field_name c cf)
	| TField(_,FEnum(en,ef)) when Meta.has Meta.FlatEnum en.e_meta ->
		spr ctx (full_enum_field_name en ef)
	| TField(_,FEnum(en,ef)) ->
		add_enum_dependency ctx en;
		print ctx "new_%s()" (full_enum_field_name en ef)
	| TField(e1,FDynamic "index") when (match follow e1.etype with TEnum(en,_) -> Meta.has Meta.FlatEnum en.e_meta | _ -> false) ->
		generate_expr ctx need_val e1
(* 	| TField(e1,FDynamic s) ->
		ctx.con.com.warning "dynamic" e.epos;
		generate_expr ctx true e1;
		print ctx "->%s" s; *)
	| TField(e1,fa) ->
		add_type_dependency ctx e.etype;
		add_type_dependency ctx e1.etype;
		let n = field_name fa in
		spr ctx "(";
		generate_expr ctx true e1;
		if is_value_type e1.etype then
			print ctx ").%s" (escape_name n)
		else
			print ctx ")->%s" (escape_name n)
	| TLocal v ->
		spr ctx (escape_name v.v_name);
	| TObjectDecl fl ->
		let s = match follow e.etype with
			| TAnon an ->
				let signature = ctx.con.get_anon_signature an.a_fields in
				add_dependency ctx DFull (["c"],signature);
				signature
			| _ -> assert false
		in
		print ctx "new_c_%s(" s;
		concat ctx "," (generate_expr ctx true) (List.map (fun (_,e) -> add_type_dependency ctx e.etype; e) fl);
		spr ctx ")";
	| TNew(c,tl,el) ->
		add_class_dependency ctx c;
		spr ctx (full_field_name c (match c.cl_constructor with None -> assert false | Some cf -> cf));
		spr ctx "(";
		concat ctx "," (generate_expr ctx true) el;
		spr ctx ")";
	| TReturn None ->
		spr ctx "return"
	| TReturn (Some e1) ->
		spr ctx "return ";
		generate_expr ctx true e1;
	| TVars(vl) ->
		let f (v,eo) =
			spr ctx (s_type_with_name ctx v.v_type v.v_name);
			begin match eo with
				| None -> ()
				| Some e ->
					spr ctx " = ";
					generate_expr ctx true e;
			end
		in
		concat ctx ";" f vl
	| TWhile(e1,e2,NormalWhile) ->
		spr ctx "while";
		generate_expr ctx true e1;
		let l = begin_loop ctx in
		generate_expr ctx false (mk_block e2);
		l()
	| TWhile(e1,e2,DoWhile) ->
		spr ctx "do";
		let l = begin_loop ctx in
		generate_expr ctx false (mk_block e2);
		spr ctx " while";
		generate_expr ctx true e1;
		l()
	| TContinue ->
		spr ctx "continue";
	| TMeta((Meta.Custom ":really",_,_), {eexpr = TBreak}) ->
		spr ctx "break";
	| TMeta((Meta.Custom ":goto",_,_), {eexpr = TConst (TInt i)}) ->
		print ctx "goto %s_%ld" (mk_runtime_prefix "label") i
	| TMeta((Meta.Custom ":label",_,_), {eexpr = TConst (TInt i)}) ->
		print ctx "%s_%ld: {}" (mk_runtime_prefix "label") i
	| TBreak ->
		let label = match ctx.fctx.loop_stack with
			| (Some s) :: _ -> s
			| None :: l ->
				let s = Printf.sprintf "%s_%i" (mk_runtime_prefix "label") ctx.con.num_labels in
				ctx.con.num_labels <- ctx.con.num_labels + 1;
				ctx.fctx.loop_stack <- (Some s) :: l;
				s
			| [] ->
				assert false
		in
		print ctx "goto %s" label;
	| TIf(e1,e2,Some e3) when need_val ->
		spr ctx "(";
		generate_expr ctx true e1;
		spr ctx " ? ";
		generate_expr ctx true e2;
		spr ctx " : ";
		generate_expr ctx true e3;
		spr ctx ")"
	| TIf(e1,e2,e3) ->
		spr ctx "if";
		generate_expr ctx true e1;
		generate_expr ctx false (mk_block e2);
		begin match e3 with
			| None -> ()
			| Some e3 ->
				spr ctx " else ";
				generate_expr ctx false (mk_block e3)
		end
	| TSwitch(e1,cases,edef) ->
		spr ctx "switch";
		generate_expr ctx true e1;
		spr ctx "{";
		let generate_case_expr e =
			let e = if Meta.has (Meta.Custom ":patternMatching") ctx.fctx.meta then e
			else Codegen.concat e (Expr.add_meta (Meta.Custom ":really") (mk TBreak e.etype e.epos)) in
			generate_expr ctx false e
		in
		let b = open_block ctx in
		List.iter (fun (el,e) ->
			newline ctx;
			spr ctx "case ";
			concat ctx "," (generate_expr ctx true) el;
			spr ctx ": ";
			generate_case_expr e;
		) cases;
		begin match edef with
			| None -> ()
			| Some e ->
				newline ctx;
				spr ctx "default: ";
				generate_case_expr e;
		end;
		b();
		newline ctx;
		spr ctx "}";
	| TBinop(OpAssign,e1,e2) ->
		generate_expr ctx need_val e1;
		spr ctx " = ";
		generate_expr ctx true e2;
	| TBinop(op,e1,e2) ->
		generate_expr ctx true e1;
		print ctx " %s " (match op with OpUShr -> ">>" | OpAssignOp OpUShr -> ">>=" | _ -> s_binop op);
		generate_expr ctx true e2;
	| TUnop(op,Prefix,e1) ->
		spr ctx (s_unop op);
		generate_expr ctx true e1;
	| TUnop(op,Postfix,e1) ->
		generate_expr ctx true e1;
		spr ctx (s_unop op);
	| TParenthesis e1 ->
		spr ctx "(";
		generate_expr ctx need_val e1;
		spr ctx ")";
	| TMeta(m,e) ->
		ctx.fctx.meta <- m :: ctx.fctx.meta;
		let e1 = generate_expr ctx need_val e in
		ctx.fctx.meta <- List.tl ctx.fctx.meta;
		e1
	| TCast(e1,_) when not need_val ->
		generate_expr ctx need_val e1
	| TCast(e1,_) ->
		begin match follow e1.etype with
		| TInst(c,_) when Meta.has Meta.Struct c.cl_meta -> generate_expr ctx true e1;
		| TAbstract({a_path = ["c"],"Pointer"},[t]) when ((s_type ctx e.etype) = "int") -> generate_expr ctx true e1;
		| _ ->
			print ctx "((%s) (" (s_type ctx e.etype);
			generate_expr ctx true e1;
			spr ctx "))"
		end
	| TEnumParameter (e1,ef,i) ->
		generate_expr ctx true e1;
		begin match follow e1.etype with
			| TEnum(en,_) ->
				add_enum_dependency ctx en;
				let s,_,_ = match ef.ef_type with TFun(args,_) -> List.nth args i | _ -> assert false in
				print ctx "->args.%s.%s" ef.ef_name s;
			| _ ->
				assert false
		end
	| TArrayDecl _ | TTry _ | TFor _ | TThrow _ | TFunction _ | TPatMatch _ ->
		(* removed by filters *)
		assert false


(* Type generation *)

let generate_function_header ctx c cf stat =
	let tf = match cf.cf_expr with
		| Some ({eexpr = TFunction tf}) -> tf
		| None ->
			assert false
		| Some e ->
			print_endline ((s_type_path c.cl_path) ^ "." ^ cf.cf_name ^ ": " ^ (s_expr_pretty "" (Type.s_type (print_context())) e));
			assert false
	in
	let sargs = List.map (fun (v,_) -> s_type_with_name ctx v.v_type v.v_name) tf.tf_args in
	let sargs = if stat then sargs else (s_type_with_name ctx (monofy_class c) "this") :: sargs in
	print ctx "%s(%s)" (s_type_with_name ctx tf.tf_type (full_field_name c cf)) (String.concat "," sargs)

let generate_typeref_forward ctx path =
	print ctx "extern const c_TypeReference %s" (get_typeref_name (path_to_name path))

let generate_typeref_declaration ctx mt =
	let path = t_path mt in
	let name = path_to_name path in
	let ctor,alloc,super = match mt with
		| TClassDecl c ->
			let s_alloc = try
				full_field_name c (PMap.find (mk_runtime_prefix "alloc") c.cl_statics)
			with Not_found ->
				"NULL"
			in
			let s_ctor = match c.cl_constructor with
				| Some cf -> full_field_name c cf
				| None -> "NULL"
			in
			let s_super = match c.cl_super with
				| None -> "NULL"
				| Some (csup,_) ->
					add_class_dependency ctx csup;
					"&" ^ (get_typeref_name (path_to_name csup.cl_path))
			in
			s_ctor,s_alloc,s_super
		| _ ->
			"NULL","NULL","NULL"
	in
	print ctx "const c_TypeReference %s = {\n" (get_typeref_name name);
	print ctx "\t\"%s\",\n" (s_type_path path);
	spr ctx "\tNULL,\n";
	print ctx "\tsizeof(%s),\n" name;
	print ctx "\t%s,\n" ctor;
	print ctx "\t%s,\n" alloc;
	print ctx "\t%s\n" super;
	spr ctx "};\n"
(* 	let path = Expr.t_path t in
	if is_value_type t then
		print ctx "const %s %s__default = { 0 }; //default" (s_type ctx t) (path_to_name path)
	else
		print ctx "const void* %s__default = NULL; //default" (path_to_name path);
	newline ctx;
	let nullval = Printf.sprintf "&%s__default" (path_to_name path) in
	Printf.sprintf "const typeref %s__typeref = { \"%s\", %s, sizeof(%s) }; //typeref declaration" (path_to_name path) (s_type_path path) nullval (s_type ctx t) *)

let generate_method ctx c cf stat =
	let e = match cf.cf_expr with
		| None -> None
		| Some {eexpr = TFunction tf} -> Some tf.tf_expr
		| Some e -> Some e
	in
	ctx.fctx <- {
		field = cf;
		loop_stack = [];
		meta = [];
	};
	let rec loop e = match e.eexpr with
		| TBlock [{eexpr = TBlock _} as e1] ->
			loop e1
		| _ ->
			Type.map_expr loop e
	in
	generate_function_header ctx c cf stat;
	begin match e with
		| None -> ()
		| Some e -> match loop e with
			| {eexpr = TBlock [] } -> spr ctx "{ }"
			| e -> generate_expr ctx false e
	end;
	newline ctx;
	spr ctx "\n"

let generate_header_fields ctx =
	let v = Var {v_read=AccNormal;v_write=AccNormal} in
	let cf_vt = Expr.mk_class_field (mk_runtime_prefix "vtable" )
		(TInst(ctx.con.hxc.c_vtable,[])) false null_pos v [] in
	let cf_hd = Expr.mk_class_field (mk_runtime_prefix "header" )
		(ctx.con.hxc.t_int64 (mk_mono())) false null_pos v [] in
	[cf_vt;cf_hd]

let generate_class ctx c =
	let vars = DynArray.create () in
	let svars = DynArray.create () in
	let methods = DynArray.create () in

	(* split fields into member vars, static vars and functions *)
	List.iter (fun cf -> match cf.cf_kind with
		| Var _ -> ()
		| Method m ->  DynArray.add methods (cf,false)
	) c.cl_ordered_fields;
	List.iter (fun cf -> match cf.cf_kind with
		| Var _ -> DynArray.add svars cf
		| Method _ -> DynArray.add methods (cf,true)
	) c.cl_ordered_statics;

	let rec loop c =
		List.iter (fun cf -> match cf.cf_kind with
			| Var _ ->
				if cf.cf_name <> (mk_runtime_prefix "header") && cf.cf_name <> (mk_runtime_prefix "vtable") then DynArray.add vars cf
			| Method m ->  ()
		) c.cl_ordered_fields;
		match c.cl_super with
		| None -> ()
		| Some (csup,_) -> loop csup
	in
	loop c;

	let path = path_to_name c.cl_path in

	if not (Meta.has (Meta.Custom ":noVTable") c.cl_meta) then
		List.iter(fun v ->
			DynArray.insert vars 0 v;
			c.cl_fields <- PMap.add v.cf_name v c.cl_fields;
		) (generate_header_fields ctx);

	(* add constructor as function *)
	begin match c.cl_constructor with
		| None -> ()
		| Some cf -> DynArray.add methods (cf,true);
	end;

	(* add init field as function *)
	begin match c.cl_init with
		| None -> ()
		| Some e ->
			ctx.con.init_modules <- c.cl_path :: ctx.con.init_modules;
			let t = tfun [] ctx.con.com.basic.tvoid in
			let f = mk_field "_hx_init" t c.cl_pos in
			let tf = {
				tf_args = [];
				tf_type = ctx.con.com.basic.tvoid;
				tf_expr = mk_block e;
			} in
			f.cf_expr <- Some (mk (TFunction tf) t c.cl_pos);
			DynArray.add methods (f,true)
	end;

	ctx.buf <- ctx.buf_c;

	generate_typeref_declaration ctx (TClassDecl c);

	(* generate static vars *)
	if not (DynArray.empty svars) then begin
		spr ctx "\n// static vars\n";
		DynArray.iter (fun cf ->
			spr ctx (s_type_with_name ctx cf.cf_type (full_field_name c cf));
			newline ctx;
		) svars;
	end;

	spr ctx "\n";

	(* generate function implementations *)
	if not (DynArray.empty methods) then begin
		DynArray.iter (fun (cf,stat) ->
			generate_method ctx c cf stat;
		) methods;
	end;

	ctx.buf <- ctx.buf_h;

	(* generate header code *)
	List.iter (function
		| Meta.HeaderCode,[(EConst(String s),_)],_ ->
			spr ctx s
		| _ -> ()
	) c.cl_meta;

	(* forward declare class type *)
	print ctx "typedef struct %s %s" path path;
	newline ctx;

	(* generate member struct *)
	if not (DynArray.empty vars) then begin
		spr ctx "\n// member var structure\n";
		print ctx "typedef struct %s {" path;
		let b = open_block ctx in
		DynArray.iter (fun cf ->
			newline ctx;
			spr ctx (s_type_with_name ctx cf.cf_type cf.cf_name);
		) vars;
		b();
		newline ctx;
		print ctx "} %s" path;
		newline ctx;
	end else begin
		print ctx "typedef struct %s { void* dummy; } %s" path path;
		newline ctx;
	end;

	(* generate static vars *)
	if not (DynArray.empty svars) then begin
		spr ctx "\n// static vars\n";
		DynArray.iter (fun cf ->
		spr ctx (s_type_with_name ctx cf.cf_type (full_field_name c cf));
		newline ctx
    ) svars
	end;

	(* generate forward declarations of functions *)
	if not (DynArray.empty methods) then begin
		spr ctx "\n// forward declarations\n";
		DynArray.iter (fun (cf,stat) ->
			generate_function_header ctx c cf stat;
			newline ctx;
		) methods;
	end;

	add_dependency ctx DForward (["c"],"TypeReference");
	generate_typeref_forward ctx c.cl_path;
	newline ctx

let generate_flat_enum ctx en =
	ctx.buf <- ctx.buf_h;
	let ctors = List.map (fun s -> PMap.find s en.e_constrs) en.e_names in
	let path = path_to_name en.e_path in
	print ctx "typedef enum %s {\n\t" path;
	let f ef = spr ctx (full_enum_field_name en ef) in
	concat ctx ",\n\t" f ctors;
	print ctx "\n} %s;" path

let generate_enum ctx en =
	ctx.buf <- ctx.buf_h;
(* 	add_dependency ctx DForward ([],"typeref");
	spr ctx (generate_typeref_forward ctx en.e_path); *)
	(* newline ctx; *)

	let ctors = List.map (fun s -> PMap.find s en.e_constrs) en.e_names in
	let path = path_to_name en.e_path in

	(* forward declare enum type *)
	print ctx "typedef struct %s %s" path path;
	newline ctx;

	(* generate constructor types *)
	spr ctx "// constructor structure";
	let ctors = List.map (fun ef ->
		newline ctx;
		match follow ef.ef_type with
		| TFun(args,_) ->
			let name = full_enum_field_name en ef in
			print ctx "typedef struct %s {" name;
			let b = open_block ctx in
			List.iter (fun (n,_,t) ->
				newline ctx;
				spr ctx (s_type_with_name ctx t n);
			) args;
			b();
			newline ctx;
			print ctx "} %s" name;
			ef
		| _ ->
			print ctx "typedef void* %s" (full_enum_field_name en ef);
			{ ef with ef_type = TFun([],ef.ef_type)}
	) ctors in

	(* generate enum type *)
	newline ctx;
	spr ctx "// enum structure";
	newline ctx;
	print ctx "typedef struct %s{" path;
	let b = open_block ctx in
	newline ctx;
	spr ctx "int index";
	newline ctx;
	spr ctx "union {";
	let b2 = open_block ctx in
	List.iter (fun ef ->
		newline ctx;
		print ctx "%s %s" (full_enum_field_name en ef) ef.ef_name
	) ctors;
	b2();
	newline ctx;
	spr ctx "} args";
	b();
	newline ctx;
	print ctx "} %s" (path_to_name en.e_path);
	newline ctx;

	spr ctx "// constructor forward declarations";
	List.iter (fun ef ->
		newline ctx;
		match ef.ef_type with
		| TFun(args,ret) ->
			print ctx "%s new_%s(%s)" (s_type ctx ret) (full_enum_field_name en ef) (String.concat "," (List.map (fun (n,_,t) -> s_type_with_name ctx t n) args));
		| _ ->
			assert false
	) ctors;
	newline ctx;

	ctx.buf <- ctx.buf_c;
	(* spr ctx (generate_typedef_declaration ctx (TEnum(en,List.map snd en.e_types))); *)
	(* newline ctx; *)

	(* generate constructor functions *)
	spr ctx "// constructor functions";
	List.iter (fun ef ->
		newline ctx;
		match ef.ef_type with
		| TFun(args,ret) ->
			print ctx "%s new_%s(%s) {" (s_type ctx ret) (full_enum_field_name en ef) (String.concat "," (List.map (fun (n,_,t) -> Printf.sprintf "%s %s" (s_type ctx t) n) args));
			let b = open_block ctx in
			newline ctx;
			print ctx "%s* this = (%s*) malloc(sizeof(%s))" path path path;
			newline ctx ;
			print ctx "this->index = %i" ef.ef_index;
			List.iter (fun (n,_,_) ->
				newline ctx;
				print ctx "this->args.%s.%s = %s" ef.ef_name n n;
			) args;
			newline ctx;
			spr ctx "return this";
			b();
			newline ctx;
			spr ctx "}"
		| _ ->
			assert false
	) ctors

let generate_type con mt = match mt with
	| TClassDecl {cl_kind = KAbstractImpl a} when Meta.has Meta.MultiType a.a_meta ->
		()
	| TClassDecl c when not c.cl_extern && not c.cl_interface ->
		let ctx = mk_type_context con c.cl_path  in
		generate_class ctx c;
		close_type_context ctx;
	| TEnumDecl en when not en.e_extern ->
		let ctx = mk_type_context con en.e_path  in
		if Meta.has Meta.FlatEnum en.e_meta then
			generate_flat_enum ctx en
		else
			generate_enum ctx en;
		close_type_context ctx;
	| TAbstractDecl { a_path = [],"Void" } -> ()
	| TAbstractDecl a when Meta.has Meta.CoreType a.a_meta ->
		let ctx = mk_type_context con a.a_path in
		ctx.buf <- ctx.buf_c;
		spr ctx " "; (* write something so the .c file is generated *)
		close_type_context ctx
	| _ ->
		()

let generate_anon con name fields =
	let ctx = mk_type_context con (["c"],name) in
	let name = "c_" ^ name in
	begin match fields with
	| [] ->
		print ctx "typedef int %s" name;
		newline ctx
	| fields ->
		spr ctx "// forward declaration";
		newline ctx;
		print ctx "typedef struct %s %s" name name;
		newline ctx;

		spr ctx "// structure";

		newline ctx;
		print ctx "typedef struct %s {" name;
		let b = open_block ctx in
		List.iter (fun cf ->
			newline ctx;
			spr ctx (s_type_with_name ctx cf.cf_type cf.cf_name);
		) fields;
		b();
		newline ctx;
		print ctx "} %s" name;
		newline ctx;
	end;

	spr ctx "// constructor forward declaration";
	newline ctx;
	print ctx "%s* new_%s(%s)" name name (String.concat "," (List.map (fun cf -> s_type_with_name ctx cf.cf_type cf.cf_name) fields));
	newline ctx;

	ctx.buf <- ctx.buf_c;

	spr ctx "// constructor definition";
	newline ctx;
	print ctx "%s* new_%s(%s) {" name name (String.concat "," (List.map (fun cf -> s_type_with_name ctx cf.cf_type cf.cf_name) fields));
	let b = open_block ctx in
	newline ctx;
	print ctx "%s* %s = (%s*) malloc(sizeof(%s))" name (mk_runtime_prefix "this") name name;
	List.iter (fun cf ->
		newline ctx;
		print ctx "%s->%s = %s" (mk_runtime_prefix "this") cf.cf_name cf.cf_name;
	) fields;
	newline ctx;
	print ctx "return %s" (mk_runtime_prefix "this");
	b();
	newline ctx;
	spr ctx "}";
	close_type_context ctx

let generate_init_file con =
	let ctx = mk_type_context con (["c"],"Init") in
	ctx.buf <- ctx.buf_c;
	spr ctx "void _hx_init() {";
	let b = open_block ctx in
	List.iter (fun path ->
		add_dependency ctx DForward path;
		newline ctx;
		print ctx "%s__hx_init()" (path_to_name path);
	) con.init_modules;
	b();
	newline ctx;
	spr ctx "}";
	ctx.buf <- ctx.buf_h;
	spr ctx "void _hx_init();";
	close_type_context ctx

let generate_make_file con =
	let relpath path = path_to_file_path path in
	let main_name = match con.com.main_class with Some path -> snd path | None -> "main" in
	let filepath = con.com.file ^ "/Makefile" in
	print_endline ("Writing " ^ filepath);
	let ch = open_out_bin filepath in
	output_string ch ("OUT = " ^ main_name ^ "\n");
	output_string ch "ifndef MSVC\n";
	output_string ch ("\tOUTFLAG := -o \n");
	output_string ch ("\tOBJEXT := o \n");
	output_string ch ("\tLDFLAGS += -lm \n");
	output_string ch ("else\n");
	output_string ch ("\tOUTFLAG := /Fo\n");
	output_string ch ("\tOBJEXT := obj\n");
	output_string ch ("\tCC := cl.exe\n");
	output_string ch ("endif\n");
	output_string ch ("all: $(OUT)\n");
	List.iter (fun ctx ->
		output_string ch (Printf.sprintf "%s.$(OBJEXT): %s.c " (relpath ctx.type_path) (relpath ctx.type_path));
		PMap.iter (fun path dept -> match dept with
			| DFull | DForward -> output_string ch (Printf.sprintf "%s.h " (relpath path))
			| _ -> ()
		) ctx.dependencies;
		output_string ch (Printf.sprintf "\n\t$(CC) $(CFLAGS) $(INCLUDES) $(OUTFLAG)%s.$(OBJEXT) -c %s.c\n\n" (relpath ctx.type_path) (relpath ctx.type_path))
	) con.generated_types;
	output_string ch "OBJECTS = ";
	List.iter (fun ctx ->
		if Buffer.length ctx.buf_c > 0 then
			output_string ch (Printf.sprintf "%s.$(OBJEXT) " (relpath ctx.type_path))
	) con.generated_types;
	output_string ch "\n\n$(OUT): $(OBJECTS)";
	output_string ch "\n\t$(CC) $(CFLAGS) $(INCLUDES) $(OBJECTS) -o $(OUT) $(LDFLAGS)\n";
	output_string ch "\n\nclean:\n\t$(RM) $(OUT) $(OBJECTS)";
	close_out ch


(* Init & main *)

let initialize_class con c =
	let add_init e = match c.cl_init with
		| None -> c.cl_init <- Some e
		| Some e2 -> c.cl_init <- Some (Codegen.concat e2 e)
	in
	let add_member_init e = match c.cl_constructor with
		| Some ({cf_expr = Some ({eexpr = TFunction tf} as ef)} as cf) ->
			cf.cf_expr <- Some ({ef with eexpr = TFunction {tf with tf_expr = Codegen.concat tf.tf_expr e}})
		| _ ->
			failwith "uhm..."
	in
	let check_dynamic cf stat = match cf.cf_kind with
		| Method MethDynamic ->
			(* create implementation field *)
			let p = cf.cf_pos in
			let cf2 = {cf with cf_name = mk_runtime_prefix cf.cf_name; cf_kind = Method MethNormal } in
			if stat then begin
				c.cl_ordered_statics <- cf2 :: c.cl_ordered_statics;
				c.cl_statics <- PMap.add cf2.cf_name cf2 c.cl_statics;
				let ef1 = Expr.mk_static_field c cf p in
				let ef2 = Expr.mk_static_field c cf2 p in
				let ef2 = Wrap.wrap_static_function con.hxc ef2 in
				add_init (Codegen.binop OpAssign ef1 ef2 ef1.etype p);
			end else begin
				let ethis = mk (TConst TThis) (monofy_class c) p in
				let ef1 = mk (TField(ethis,FInstance(c,cf))) cf.cf_type p in
				let ef2 = mk (TField(ethis,FStatic(c,cf2))) cf2.cf_type p in
				let ef2 = Wrap.wrap_function con.hxc ethis ef2 in
				add_member_init (Codegen.binop OpAssign ef1 ef2 ef1.etype p);
				c.cl_ordered_fields <- cf2 :: c.cl_ordered_fields;
				c.cl_fields <- PMap.add cf2.cf_name cf2 c.cl_fields
			end;
			cf.cf_expr <- None;
			cf.cf_kind <- Var {v_read = AccNormal; v_write = AccNormal};
			cf.cf_type <- con.hxc.t_closure cf.cf_type;
		| _ ->
			()
	in

	let check_closure cf = match cf.cf_type with
		| TFun _ -> cf.cf_type <- con.hxc.t_closure cf.cf_type;
		| _ -> ()
	in

	let infer_null_argument cf =
		match cf.cf_expr,follow cf.cf_type with
			| Some ({eexpr = TFunction tf} as e),TFun(args,tr) ->
				let args = List.map2 (fun (v,co) (n,o,t) ->
					let t = if not o && co = None then
						t
					else if is_null v.v_type then
						v.v_type
					else begin
						v.v_type <- con.com.basic.tnull v.v_type;
						v.v_type
					end in
					n,o,t
				) tf.tf_args args in
				cf.cf_type <- TFun(args,tr);
				cf.cf_expr <- Some ({e with etype = cf.cf_type})
			| _ ->
				()
	in

	List.iter (fun cf ->
		(match cf.cf_expr with Some e -> Analyzer.run e | _ -> ());
		match cf.cf_kind with
		| Var _ -> check_closure cf
		| Method m -> match cf.cf_type with
			| TFun(_) ->
				infer_null_argument cf;
				check_dynamic cf false;
			| _ -> assert false;
	) c.cl_ordered_fields;

	List.iter (fun cf ->
		(match cf.cf_expr with Some e -> Analyzer.run e | _ -> ());
		match cf.cf_kind with
		| Var _ ->
			check_closure cf;
			begin match cf.cf_expr with
				| None -> ()
				| Some e ->
					(* add static var initialization to cl_init *)
					let ta = TAnon { a_fields = c.cl_statics; a_status = ref (Statics c) } in
					let ethis = mk (TTypeExpr (TClassDecl c)) ta cf.cf_pos in
					let efield = Codegen.field ethis cf.cf_name cf.cf_type cf.cf_pos in
					let eassign = mk (TBinop(OpAssign,efield,e)) efield.etype cf.cf_pos in
					cf.cf_expr <- Some eassign;
					add_init eassign;
			end
		| Method _ ->
			infer_null_argument cf;
			check_dynamic cf true;
	) c.cl_ordered_statics;

	begin match c.cl_constructor with
		| Some cf -> infer_null_argument cf
		| _ -> ()
	end;

	if not (Meta.has (Meta.Custom ":noVTable") c.cl_meta) then begin
		let v = Var {v_read=AccNormal;v_write=AccNormal} in
		let cf_vt = Expr.mk_class_field (mk_runtime_prefix "vtable") (TInst(con.hxc.c_vtable,[])) false null_pos v [] in
		let cf_hd = Expr.mk_class_field (mk_runtime_prefix "header") (con.hxc.t_int64 (mk_mono())) false null_pos v [] in
		c.cl_ordered_fields <- cf_vt :: cf_hd :: c.cl_ordered_fields;
		c.cl_fields <- PMap.add cf_vt.cf_name cf_vt (PMap.add cf_hd.cf_name cf_hd c.cl_fields);
	end;

	let e_typeref = Expr.mk_ccode con ("&" ^ (get_typeref_name (path_to_name c.cl_path))) c.cl_pos in
	let e_init = Expr.mk_static_call_2 con.hxc.c_boot "registerType" [e_typeref] c.cl_pos in
	add_init e_init

let initialize_constructor con c cf =
	match cf.cf_expr with
	| Some ({eexpr = TFunction tf} as e) ->
		let p = e.epos in
		let t_class = monofy_class c in
		let e_alloc = if is_value_type t_class then
			Expr.mk_ccode con ("{0}; //semicolon") p
		else
			let e_size = Expr.mk_ccode con (Printf.sprintf "sizeof(%s)" (path_to_name c.cl_path)) p in
			Expr.mk_static_call_2 con.hxc.c_cstdlib "calloc" [Expr.mk_int con.com 1 p;e_size] p
		in
		let v_this = alloc_var "this" t_class in
		let e_this = Expr.mk_local v_this p in
		let el_vt = try
			let cf_vt = PMap.find (mk_runtime_prefix "vtable") c.cl_fields in
			let e_vt = mk (TField(e_this,FInstance(c,cf_vt))) cf_vt.cf_type null_pos in
			let easgn = Expr.mk_binop OpAssign e_vt (Expr.mk_static_field_2 c (mk_runtime_prefix "_vtable") null_pos ) cf_vt.cf_type null_pos in
			[easgn]
		with Not_found ->
			[]
		in
		let args = List.map (fun (v,_) -> v.v_name,false,v.v_type) tf.tf_args in
		let mk_ctor_init () =
			let cf_init = Expr.mk_class_field (mk_runtime_prefix "initInstance") (TFun((v_this.v_name,false,v_this.v_type) :: args,con.com.basic.tvoid)) false p (Method MethNormal) [] in
			let rec map_this e = match e.eexpr with
				| TConst TThis -> e_this
				| _ -> Type.map_expr map_this e
			in
			let tf_ctor = {
				tf_args = (v_this,None) :: List.map (fun (v,_) -> v,None) tf.tf_args;
				tf_type = con.com.basic.tvoid;
				tf_expr = map_this tf.tf_expr;
			} in
			cf_init.cf_expr <- Some (mk (TFunction tf_ctor) cf_init.cf_type p);
			c.cl_ordered_statics <- cf_init :: c.cl_ordered_statics;
			c.cl_statics <- PMap.add cf_init.cf_name cf_init c.cl_statics;
			let ctor_args = List.map (fun (v,_) -> Expr.mk_local v p) tf.tf_args in
			Expr.mk_static_call c cf_init (e_this :: ctor_args) p
		in
		let e_vars = mk (TVars [v_this,Some e_alloc]) con.com.basic.tvoid p in
		let e_return = mk (TReturn (Some e_this)) t_dynamic p in
		let e_init = if is_value_type t_class then
			tf.tf_expr
		else
			mk_ctor_init ()
		in
		let tf_alloc = {
			tf_args = [];
			tf_type = t_class;
			tf_expr = Expr.mk_block con.com p (e_vars :: el_vt @ [e_return]);
		} in
		let cf_alloc = Expr.mk_class_field (mk_runtime_prefix "alloc") (tfun [] t_class) false p (Method MethNormal) [] in
		cf_alloc.cf_expr <- Some (mk (TFunction tf_alloc) cf_alloc.cf_type cf_alloc.cf_pos);
		c.cl_ordered_statics <- cf_alloc :: c.cl_ordered_statics;
		c.cl_statics <- PMap.add cf_alloc.cf_name cf_alloc c.cl_statics;
		let tf = {
			tf_args = tf.tf_args;
			tf_type = t_class;
			tf_expr = mk (TBlock [
				mk (TVars [v_this,Some (Expr.mk_static_call c cf_alloc [] p)]) con.com.basic.tvoid p;
				e_init;
				e_return
			]) t_class p;
		} in
		cf.cf_expr <- Some {e with eexpr = TFunction tf};
		cf.cf_type <- TFun(args, t_class)
	| _ ->
		()

let generate com =
	let rec find_class path mtl = match mtl with
		| TClassDecl c :: _ when c.cl_path = path -> c
		| _ :: mtl -> find_class path mtl
		| [] -> assert false
	in
	let c_lib = find_class (["c"],"Lib") com.types in
	let null_func _ = assert false in
	let hxc = List.fold_left (fun acc mt -> match mt with
		| TClassDecl c ->
			begin match c.cl_path with
				| [],"jmp_buf" -> {acc with t_jmp_buf = TInst(c,[])}
				| [],"hxc" -> {acc with c_boot = c}
				| [],"String" -> {acc with c_string = c}
				| [],"Array" -> {acc with c_array = c}
				| ["c"],"TypeReference" -> {acc with t_typeref = fun t -> TInst(c,[t])}
				| ["c"],"FixedArray" -> {acc with c_fixed_array = c}
				| ["c"],"Exception" -> {acc with c_exception = c}
				| ["c"],"Closure" -> {acc with t_closure = fun t -> TInst(c,[t])}
				| ["c"],"CString" -> {acc with c_cstring = c}
				| ["c"],"CStdlib" -> {acc with c_cstdlib = c}
				| ["c"],"CSetjmp" -> {acc with c_csetjmp = c}
				| ["c"],"CStdio" -> {acc with c_cstdio = c}
				| ["c"],"VTable" -> {acc with c_vtable = c}
				| _ -> acc
			end
		| TAbstractDecl a ->
			begin match a.a_path with
			| ["c"],"ConstSizeArray" ->
				acc
			| ["c"],"Pointer" ->
				{acc with t_pointer = fun t -> TAbstract(a,[t])}
			| ["c"],"ConstPointer" ->
				{acc with t_const_pointer = fun t -> TAbstract(a,[t])}
			| ["c"],"FunctionPointer" ->
				{acc with t_func_pointer = fun t -> TAbstract(a,[t])}
			| ["c"],"Int64" ->
				{acc with t_int64 = fun t -> TAbstract(a,[t])}
			| ["c"],"VarArg" ->
				{acc with t_vararg = TAbstract(a,[])}
			| _ ->
				acc
			end
		| _ ->
			acc
	) {
		c_lib = c_lib;
		cf_deref = PMap.find "dereference" c_lib.cl_statics;
		cf_addressof = PMap.find "getAddress" c_lib.cl_statics;
		cf_sizeof = PMap.find "sizeof" c_lib.cl_statics;
		t_typeref = null_func;
		t_pointer = null_func;
		t_closure = null_func;
		t_const_pointer = null_func;
		t_func_pointer = null_func;
		t_int64 = null_func;
		t_jmp_buf = t_dynamic;
		t_vararg = t_dynamic;
		c_boot = null_class;
		c_exception = null_class;
		c_string = null_class;
		c_array = null_class;
		c_fixed_array = null_class;
		c_cstring = null_class;
		c_csetjmp = null_class;
		c_cstdlib = null_class;
		c_cstdio = null_class;
		c_vtable = null_class;
	} com.types in
	let anons = ref PMap.empty in
	let added_anons = ref PMap.empty in
	let get_anon =
		let num_anons = ref 0 in
		fun fields ->
			let fields = pmap_to_list fields in
			let fields = sort_anon_fields fields in
			let id = String.concat "," (List.map (fun cf -> cf.cf_name ^ (Type.s_type (print_context()) (follow cf.cf_type))) fields) in
			let s = try
				fst (PMap.find id !anons)
			with Not_found ->
				incr num_anons;
				let s = mk_runtime_prefix  ("anon_" ^ (string_of_int !num_anons)) in
				anons := PMap.add id (s,fields) !anons;
				added_anons := PMap.add id (s,fields) !added_anons;
				s
			in
			s
	in
	let con = {
		com = com;
		hxc = hxc;
		num_temp_funcs = 0;
		num_labels = 0;
		(* this has to start at 0 so the first type id is 1 *)
		num_identified_types = 0;
		type_ids = PMap.empty;
		type_parameters = PMap.empty;
		init_modules = [];
		generated_types = [];
		get_anon_signature = get_anon;
	} in
	List.iter (fun mt -> match mt with
		| TClassDecl c -> initialize_class con c
		| _ -> ()
	) com.types;
	VTableHandler.get_chains con com.types;
	List.iter (fun mt -> match mt with
		| TClassDecl ({cl_constructor = Some cf} as c) -> initialize_constructor con c cf
		| _ -> ()
	) com.types;
	(* ascending priority *)
	let filters = [
		DefaultValues.filter;
		ExprTransformation2.filter
	] in

	let gen = Filters.mk_gen_context con in
	List.iter (Filters.add_filter gen) filters;
	Filters.run_filters_types gen;
	let filters = [
		VarDeclarations.filter;
		ExprTransformation.filter;
		ArrayHandler.filter;
		TypeChecker.filter;
		StringHandler.filter;
		SwitchHandler.filter;
		ClosureHandler.filter;
		DefaultValues.handle_call_site;
	] in
	let gen = Filters.mk_gen_context con in
	List.iter (Filters.add_filter gen) filters;
	Filters.run_filters_types gen;

	List.iter (generate_type con) com.types;
	let rec loop () =
		let anons = !added_anons in
		added_anons := PMap.empty;
		PMap.iter (fun _ (s,cfl) -> generate_anon con s cfl) anons;
		if not (PMap.is_empty !added_anons) then loop()
	in
	loop();
	generate_init_file con;
	generate_make_file con
