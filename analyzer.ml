open Ast
open Type

	let assigns_to_trace = ref false

	let rec run e =
		match e.eexpr with
		| TBinop(OpAssign, {eexpr = TField(_,FStatic({cl_path=["haxe"],"Log"}, {cf_name = "trace"}))}, _) ->
			assigns_to_trace := true
		| _ ->
			Type.iter run e


type gconstant_t = int
and gtype_t = int
and gvar_t  = Type.tvar
and ganon_t = int
and gclass_t = Type.tclass
and gfunc_t = (Type.tfunc * gexpr_t)
and gfield_access_t = tfield_access
and gmodule_type_t = int
and gdecision_tree_t = int
and genum_field_t = int
and gnode_t =
	| GNone
	| GWhatever of (int * gexpr_t)

and gdata_value =
	| GDInst of int * tclass
	| GDEnum of int * tenum
	| GDAnon of int * tanon

and gdbranch_instruction_t = {

	mutable gdb_idx : int;   (* index of currently evaluated branch always < gdb_max*)

	gdb_max   : int;         (* number of alternative branches *)

	gdb_exprs : gexpr_t array; (* the child expressions of this branch in an array, for random access *)

	gdb_seq   : gdbranch_instruction_t array array;
							 (* an array for each sequence of branch instructions per child expressison *)

	mutable gdb_cur : int;   (* index of currently evaluated execution path, always < gdb_total*)

	gdb_total : int;         (* total number of execution paths when iterating over this branch *)
}

and gdbranch_t =
	| GDBIf
	| GDBIfElse
	| GDBSwitch

and gdata_t =
	| GDNone
	| GDBlockInfo of ( int * gdata_t list )
	| GDBranchDone
	| GDBranchState of gdbranch_instruction_t

and gexpr_t = {
	g_te  : Type.texpr;
	gtype : Type.t;
	gexpr : gexpr_expr_t;
	mutable gdata : gdata_t;
}
	(*| GE of (texpr * gexpr_expr_t)
	| GMergeBlock of (texpr * gexpr_expr_t) list*)


and gexpr_expr_t    =
	| GConst of gconstant_t
	| GLocal of gvar_t
	| GArray of gexpr_t * gexpr_t
	| GBinop of Ast.binop * gexpr_t * gexpr_t
	| GField of gexpr_t * gfield_access_t
	| GTypeExpr of gmodule_type_t
	| GParenthesis of gexpr_t
	| GObjectDecl of (string * gexpr_t) list
	| GArrayDecl of gexpr_t list
	| GCall of gexpr_t * gexpr_t list
	| GNew of gclass_t * tparams * gexpr_t list
	| GUnop of Ast.unop * Ast.unop_flag * gexpr_t
	| GFunction of gfunc_t
	| GVars of (gvar_t * gexpr_t option) list
	| GSVar of (gvar_t * gexpr_t)
	| GNVar of  gvar_t
	| GBlock of gexpr_t list
	| GFor of gvar_t * gexpr_t * gexpr_t
	| GIf of gexpr_t * gexpr_t * gexpr_t option
	| GWhile of gexpr_t * gexpr_t * Ast.while_flag
	| GSwitch of gexpr_t * (gexpr_t list * gexpr_t) list * gexpr_t option
	| GPatMatch of gdecision_tree_t
	| GTry of gexpr_t * (gvar_t * gexpr_t) list
	| GReturn of gexpr_t option
	| GBreak
	| GContinue
	| GThrow of gexpr_t
	| GCast of gexpr_t * gmodule_type_t option
	| GMeta of metadata_entry * gexpr_t
	| GEnumParameter of gexpr_t * genum_field_t * int
	| GNode of gnode_t

let s_gdata v = match v with
	| GDNone -> "no data"
	| GDBranchDone -> "brdone data"
	| GDBranchState _ -> "brstate data"
	| GDBlockInfo _ -> "blockinfo data"

let fdefault v:'a = 0
let fid      v:'a = v
let ftype          = fdefault
let fconstant      = fdefault
let fvar           = fid
let fexpr          = fdefault
let fanon          = fdefault
let fclass         = fid
let ffield_access  = fid
let fmodule_type   = fdefault
let fdecision_tree = fdefault
let fenum_field    = fdefault

let gdata_default () = GDNone

let map_expr f  ( e : Type.texpr ) =
	let te = e in
	match e.eexpr with
	| TConst v ->  { g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =  GConst (fconstant v) }
	| TLocal v ->  { g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =  GLocal (fvar v) }
	| TBreak   ->  { g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =  GBreak }
	| TContinue -> { g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =  GContinue }
	| TTypeExpr mt -> { g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =  GTypeExpr (fmodule_type mt) }
	| TArray (e1,e2) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GArray (f e1,f e2) }
	| TBinop (op,e1,e2) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GBinop (op,f e1,f e2) }
	| TFor (v,e1,e2) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GFor (fvar v,f e1,f e2) }
	| TWhile (e1,e2,flag) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GWhile (f e1,f e2,flag) }
	| TThrow e1 ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GThrow (f e1) }
	| TEnumParameter (e1,ef,i) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GEnumParameter(f e1,fenum_field ef,i) }
	| TField (e1,v) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GField (f e1, ffield_access v) }
	| TParenthesis e1 ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GParenthesis (f e1) }
	| TUnop (op,pre,e1) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GUnop (op,pre,f e1) }
	| TArrayDecl el ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GArrayDecl (List.map f el) }
	| TNew (t,pl,el) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GNew (fclass t,pl,List.map f el) }
	| TBlock el ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GBlock (List.map f el) }
	| TObjectDecl el ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GObjectDecl (List.map (fun (v,e) -> v, f e) el) }
	| TCall (e1,el) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GCall (f e1, List.map f el) }
	| TVars vl ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GVars (List.map (fun (v,e) -> fvar v , match e with None -> None | Some e -> Some (f e)) vl) }
	| TFunction tf ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GFunction (tf, f tf.tf_expr) }
	| TIf (ec,e1,e2) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GIf (f ec,f e1,match e2 with None -> None | Some e -> Some (f e)) }
	| TSwitch (e1,cases,def) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GSwitch (f e1, List.map (fun (el,e2) -> List.map f el, f e2) cases, match def with None -> None | Some e -> Some (f e)) }
	| TPatMatch dt ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GPatMatch( fdecision_tree dt ) }
	| TTry (e1,catches) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GTry (f e1, List.map (fun (v,e) -> fvar v, f e) catches) }
	| TReturn eo ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GReturn (match eo with None -> None | Some e -> Some (f e)) }
	| TCast (e1,t) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GCast (f e1, match t with None -> None | Some mt -> Some (fmodule_type mt)) }
	| TMeta (m,e1) ->
		{ g_te = te; gtype = te.etype; gdata = gdata_default(); gexpr =   GMeta(m,f e1) }

let map_gexpr f e : gexpr_t = match e.gexpr with
		| GConst _
		| GLocal _
		| GBreak
		| GContinue
		| GTypeExpr _ ->
			e
		| GArray (e1,e2) ->
			{ e with gexpr =   GArray (f e1,f e2) }
		| GBinop (op,e1,e2) ->
			{ e with gexpr =   GBinop (op,f e1,f e2) }
		| GFor (v,e1,e2) ->
			{ e with gexpr =   GFor ( v,f e1,f e2) }
		| GWhile (e1,e2,flag) ->
			{ e with gexpr =   GWhile (f e1,f e2,flag) }
		| GThrow e1 ->
			{ e with gexpr =   GThrow (f e1) }
		| GEnumParameter (e1,ef,i) ->
			{ e with gexpr =   GEnumParameter(f e1, ef,i) }
		| GField (e1,v) ->
			{ e with gexpr =   GField (f e1, v) }
		| GParenthesis e1 ->
			{ e with gexpr =   GParenthesis (f e1) }
		| GUnop (op,pre,e1) ->
			{ e with gexpr =   GUnop (op,pre,f e1) }
		| GArrayDecl el ->
			{ e with gexpr =   GArrayDecl (List.map f el) }
		| GNew (t,pl,el) ->
			{ e with gexpr =   GNew (fclass t,pl,List.map f el) }
		| GBlock el ->
			{ e with gexpr =   GBlock (List.map f el) }
		| GObjectDecl el ->
			{ e with gexpr =   GObjectDecl (List.map (fun (v,e) -> v, f e) el) }
		| GCall (e1,el) ->
			{ e with gexpr =   GCall (f e1, List.map f el) }
		| GNVar _ ->
			e
		| GSVar(v, e) ->
			{ e with gexpr =   GSVar (v, f e) }
		| GVars vl ->
			{ e with gexpr =   GVars (List.map (fun (v,e) -> fvar v , match e with None -> None | Some e -> Some (f e)) vl) }
		| GFunction (tf, e) ->
			{ e with gexpr =   GFunction (tf, f e) }
		| GIf (ec,e1,e2) ->
			{ e with gexpr =   GIf (f ec,f e1,match e2 with None -> None | Some e -> Some (f e)) }
		| GSwitch (e1,cases,def) ->
			{ e with gexpr =   GSwitch (f e1, List.map (fun (el,e2) -> List.map f el, f e2) cases, match def with None -> None | Some e -> Some (f e)) }
		| GPatMatch dt ->
			{ e with gexpr =   GPatMatch( dt ) }
		| GTry (e1,catches) ->
			{ e with gexpr =   GTry (f e1, List.map (fun (v,e) -> fvar v, f e) catches) }
		| GReturn eo ->
			{ e with gexpr =   GReturn (match eo with None -> None | Some e -> Some (f e)) }
		| GCast (e1,t) ->
			{ e with gexpr =   GCast (f e1, match t with None -> None | Some mt -> Some (mt)) }
		| GMeta (m,e1) ->
			{ e with gexpr =   GMeta(m,f e1) }
		| GNode _ -> assert false


let fold_gexpr (f : 'a -> gexpr_t -> 'a) (acc : 'a) ( e : gexpr_t)  : 'a = match e.gexpr with
		| GConst _
		| GLocal _
		| GBreak
		| GContinue
		| GTypeExpr _ ->
			acc
		| GArray (e1,e2)
		| GBinop (_,e1,e2)
		| GFor (_,e1,e2)
		| GWhile (e1,e2,_) ->
			let acc = f acc e1 in
			f acc e2
		| GThrow e
		| GField (e,_)
		| GEnumParameter (e,_,_)
		| GParenthesis e
		| GCast (e,_)
		| GUnop (_,_,e)
		| GMeta(_,e) ->
			f acc e
		| GArrayDecl el
		| GNew (_,_,el)
		| GBlock el ->
			List.fold_left (fun acc e -> f acc e) acc el
		| GObjectDecl fl ->
			List.fold_left (fun acc (_,e) -> f acc e) acc fl
		| GCall (e,el) ->
			let acc = f acc e in
			List.fold_left (fun acc e -> f acc e) acc el
		| GVars vl ->
			List.fold_left (fun acc (_,e) -> match e with None -> acc | Some e -> f acc e) acc vl
		| GNVar v -> acc
		| GSVar (v, e) -> f acc e
		| GFunction (tf, e) ->
			f acc e
		| GIf (e,e1,e2) ->
			let acc = f acc e in
			let acc = f acc e1 in
			(match e2 with None -> acc | Some e -> f acc e)
		| GSwitch (e,cases,def) ->
			let acc = f acc e in
			let acc = List.fold_left (fun acc (el,e2) ->
				let acc = List.fold_left (fun acc e-> f acc e) acc el in
				f acc e2 ) acc cases in
			(match def with None -> acc | Some e -> f acc e)
		| GPatMatch dt -> acc
		| GTry (e,catches) ->
			let acc = f acc e in
			List.fold_left (fun acc (_,e) -> f acc e) acc catches
		| GReturn eo ->
			(match eo with None -> acc | Some e -> f acc e)
		| GNode _ -> assert false


let iter_gexpr f e : unit = match e.gexpr with
		| GConst _
		| GLocal _
		| GBreak
		| GContinue
		| GTypeExpr _ ->
			()
		| GArray (e1,e2)
		| GBinop (_,e1,e2)
		| GFor (_,e1,e2)
		| GWhile (e1,e2,_) ->
			f e1;
			f e2;
		| GThrow e
		| GField (e,_)
		| GEnumParameter (e,_,_)
		| GParenthesis e
		| GCast (e,_)
		| GUnop (_,_,e)
		| GMeta(_,e) ->
			f e
		| GArrayDecl el
		| GNew (_,_,el)
		| GBlock el ->
			List.iter f el
		| GObjectDecl fl ->
			List.iter (fun (_,e) -> f e) fl
		| GCall (e,el) ->
			f e;
			List.iter f el
		| GVars vl ->
			List.iter (fun (_,e) -> match e with None -> () | Some e -> f e) vl
		| GNVar v -> ()
		| GSVar (v, e) -> f e
		| GFunction (tf, e) ->
			f e
		| GIf (e,e1,e2) ->
			f e;
			f e1;
			(match e2 with None -> () | Some e -> f e)
		| GSwitch (e,cases,def) ->
			f e;
			List.iter (fun (el,e2) -> List.iter f el; f e2) cases;
			(match def with None -> () | Some e -> f e)
		| GPatMatch dt -> ()
		| GTry (e,catches) ->
			f e;
			List.iter (fun (_,e) -> f e) catches
		| GReturn eo ->
			(match eo with None -> () | Some e -> f e)
		| GNode _ -> assert false

let s_gexpr e  = match e.gexpr with
		| GConst _ -> "GConst"
		| GLocal v -> "GLocal " ^ v.v_name
		| GBreak -> "GBreak"
		| GContinue -> "GContinue"
		| GVars _ -> "GVars"
		| GCall _ -> "GCall"
		| GBinop _ -> "GBinop"
		| GUnop _ -> "GUnop"
		| GNew (c,_,_) -> "GNew " ^ (snd c.cl_path)
		| _ -> ""
(*		| GTypeExpr _ ->
			()
		| GArray (e1,e2)
		| GBinop (_,e1,e2)
		| GFor (_,e1,e2)
		| GWhile (e1,e2,_) ->
			f e1;
			f e2;
		| GThrow e
		| GField (e,_)
		| GEnumParameter (e,_,_)
		| GParenthesis e
		| GCast (e,_)
		| GUnop (_,_,e)
		| GMeta(_,e) ->
			f e
		| GArrayDecl el
		| GNew (_,_,el)
		| GBlock el ->
			List.iter f el
		| GObjectDecl fl ->
			List.iter (fun (_,e) -> f e) fl
		| GCall (e,el) ->
			f e;
			List.iter f el
		| GVars vl ->
			List.iter (fun (_,e) -> match e with None -> () | Some e -> f e) vl
		| GNVar v -> ()
		| GSVar (v, e) -> f e
		| GFunction (tf, e) ->
			f e
		| GIf (e,e1,e2) ->
			f e;
			f e1;
			(match e2 with None -> () | Some e -> f e)
		| GSwitch (e,cases,def) ->
			f e;
			List.iter (fun (el,e2) -> List.iter f el; f e2) cases;
			(match def with None -> () | Some e -> f e)
		| GPatMatch dt -> ()
		| GTry (e,catches) ->
			f e;
			List.iter (fun (_,e) -> f e) catches
		| GReturn eo ->
			(match eo with None -> () | Some e -> f e)
		| GNode _ -> assert false*)

(* ---------------------------------------------------------------------- *)


(*

	how do values get into scope?

	1. they are constructed in scope.
	2. they are passed via function arguments
	3. they are fields of the class instance
	3. they are static fields



	how are values accessed?
(* 	when accessing a static fieldzdfzd *)

	accessed value id via path from scope id


	access this.field.field
	access typeexpr.field.field.


	3     0       0       1       1       2       2
	2     0       1       0       1       0       1
	4     0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3


*)






(* ----------------------------  Interpreter  --------------------------- *)

type gr_id  = int
type gr_tid = int
type gr_iid = int

type gr_func = gexpr_t

and gr_global_ctx = {

	gr_classes : gr_sclass  DynArray.t;
	gr_enums   : gr_senum   DynArray.t;
	gr_anons   : gr_sanon   DynArray.t;

	gr_iclasses: gr_class   DynArray.t;
	gr_ienums  : gr_enum    DynArray.t;
	gr_ianon   : gr_anon    DynArray.t;
	gr_iclosure: gr_closure DynArray.t;

}

and gr_origin_t =
    | GROStatic
    | GROInst
    | GROArg
    | GROLocal

and gr_op_t =
	| GRONew    of gr_value
	| GROAssign of gr_value * gr_value
	| GROCall   of gr_value * gr_value list
	| GROAccess of gr_value

and gr_function_ctx = {
	gr_fcx_id     : gr_id;
	gr_fcx_locals : (int,gr_value) PMap.t;
}

and gr_branch_ctx = {
	gr_bcx_id  : gr_id;
	gr_bcx_ops : gr_op_t list;
}

and gr_scope = {
	gsc_id    : gr_id;
	gsc_vars  : gr_value DynArray.t;
}

and gr_fields = {
	gf_size   : int;
	gf_values : (int,int) Hashtbl.t;
}

and gr_class = {
	gcl_id     : gr_tid;
	gcl_iid    : gr_iid;
	gcl_vars   : gr_value DynArray.t;
}
and gr_sclass = {
	gcl_tid       : gr_tid;
	gcl_sfields   : gr_value DynArray.t;

	gcl_var_map   : gr_fields;
	gcl_svar_map  : gr_fields;

	gcl_methods   : gr_func DynArray.t;
	gcl_smethods  : gr_func DynArray.t;
}

and gr_closure = {
	gclr_id   : gr_tid;
	gclr_iid  : gr_iid;
	gclr_ctx  : gr_value DynArray.t;
	gclr_func : gr_func;
}

and gr_enum = {
	gen_id       : gr_tid;
	gen_iid      : gr_iid;
	gen_idx      : int;
	gen_fields   : gr_value DynArray.t;
}

and gr_senum = {
	gen_tid     : gr_tid;
	gen_con_map : (int,gr_fields) Hashtbl.t;
}

and gr_anon = {
	ga_id        : gr_tid;
	ga_iid       : gr_iid;
	ga_fields    : gr_value DynArray.t;
}

and gr_sanon = {
	ga_tid      : gr_tid;
	ga_var_map  : gr_fields;
}

and gr_value_t =
	| GRClass   of gr_class
	| GRSClass  of gr_sclass
	| GRAnon    of gr_anon
	| GREnum    of gr_enum
	| GRArray   of int DynArray.t
	| GRClosure of gr_closure
	| GRString  of string
	| GRInt     of Int32.t
	| GRInt64   of Int64.t
	| GRFloat   of string
	| GRBool    of bool
	| GRNull


and gr_value = {
	grv_val   : gr_value_t;
	grv_refs  : gr_value_t list;

}

and gr_state = {
	gst_id  : gr_id;
	(*gst_pid : gr_id;*)
}

let gr_null_val = { grv_val = GRNull; grv_refs = []}

let gf_set_field fields idx v =
	DynArray.unsafe_set fields idx v

let gf_get_field fields idx =
	DynArray.unsafe_get fields idx

let gr_set_field ctx self n v = try ( match self with
	| GRClass c ->
		let scl  = DynArray.unsafe_get ctx.gr_classes c.gcl_id in
		let fidx = Hashtbl.find scl.gcl_var_map.gf_values n in
		gf_set_field c.gcl_vars fidx v
	| GRAnon a ->
		let s  = DynArray.unsafe_get ctx.gr_anons a.ga_id in
		let fidx = Hashtbl.find s.ga_var_map.gf_values n in
		gf_set_field a.ga_fields fidx v
	| _ -> assert false
	) with Not_found -> assert false

let gr_get_field ctx self n = try ( match self with
	| GRClass c ->
		let scl  = DynArray.unsafe_get ctx.gr_classes c.gcl_id in
		let fidx = Hashtbl.find scl.gcl_var_map.gf_values n in
		gf_get_field c.gcl_vars fidx
	| GRAnon a ->
		let s  = DynArray.unsafe_get ctx.gr_anons a.ga_id in
		let fidx = Hashtbl.find s.ga_var_map.gf_values n in
		gf_get_field a.ga_fields fidx
	| _ -> assert false
	) with Not_found -> assert false

let gcl_init_class ctx tid =
	let scl  = DynArray.unsafe_get ctx.gr_classes tid in
	let v = {
		gcl_id     = scl.gcl_tid;
		gcl_iid    = DynArray.length ctx.gr_iclasses;
		gcl_vars   = DynArray.init scl.gcl_var_map.gf_size (fun _-> gr_null_val)
	} in
	DynArray.add ctx.gr_iclasses v;
	v

let gen_init_enum ctx tid eidx =
	let s  = DynArray.unsafe_get ctx.gr_enums tid in
	let gfields = Hashtbl.find s.gen_con_map eidx in
	let v = {
		gen_id     = tid;
		gen_iid    = DynArray.length ctx.gr_ienums;
		gen_idx    = eidx;
		gen_fields = DynArray.init gfields.gf_size (fun _-> gr_null_val)
	} in
	DynArray.add ctx.gr_ienums v;
	v


(*
ctx requires:
- this
- super
- current scope
- state
*)



let gr_new_var ctx = ()
	(*ctx.scope*)

let gr_open_scope ctx = ()
	(*let ctx = { ctx with scope = }*)

let gr_close_scope ctx = ()



let gr_getval_var v : gr_value = gr_null_val

let gr_getval_typeexpr : gr_value = gr_null_val

(*
	What we do is:
	1.
*)
let gr_open_branch ctx  = ()


let gr_close_branch ctx = ()

type gr_state_ctx = {
	xxx : int;
}

(*let eval_gexpr f ctx e : gr_value = match e.gexpr with
	| GIf (e,e1,e2) ->
		f e;
		f e1;
		(match e2 with None -> gr_null_val | Some e -> f e)

	| GSwitch (e,cases,def) ->
		f e;
		List.iter (fun (el,e2) -> List.iter f el; f e2) cases;
		(match def with None -> gr_null_val | Some e -> f e)

	| _ ->*)

type grstate = int

(*
let eval_merge (states : gr_state list) ( f : gr_state list -> gexpr_t -> gr_state list ) e =
let nstates = List.fold_left ( fun acc st -> (f st e) :: acc ) [] states in
	List.flatten nstates

let eval_merge_seq states f el =
	List.fold_left ( fun acc e ->
		eval_merge acc f e
	) states el*)

let flatten xxs =
	let rec inner xs acc = match xs with
	| x :: xs -> inner xs (x :: acc)
	| []      -> acc
	in
	let rec outer xxs acc = match xxs with
	| xs :: xxs -> outer xxs (inner xs acc)
	| [] -> acc
	in match xxs with
	| xs :: xxs -> (outer xxs xs)
	| [] -> []


let eval_seq states f el =
	List.fold_left ( fun acc e -> f states e ) states el

let eval_map states f e =
	List.map (fun st -> f st) states

(*
let eval_func f ctx states e = match e.gexpr with
	| *)



let eval_branches states e =
	let rec f ctx states e : gr_state list = match e.gexpr with
	| GIf (e,e1,e2) ->
		let rstates = List.rev_map ( fun st->
			let cond_states = f ctx [st] e in
			let if_states   = f ctx cond_states e1 in (match e2 with
				| None ->
					flatten [cond_states;if_states]
				| Some e ->
					let else_states = f ctx cond_states e in
					flatten [if_states;else_states]
			)
		) states in
		flatten rstates
	| GSwitch (e,cases,def) ->
		let cond_states = f ctx states e in
		let case_cond_states,case_states = List.fold_left ( fun (states,rstates) (el,e2) ->
			let case_cond_states = eval_seq states (f ctx) el in
			let case_states      = f ctx case_cond_states e2 in
			(case_cond_states, case_states :: rstates)
		) (cond_states,[]) cases
		in
		let rstates = ( match def with
			| None -> case_states
			| Some e ->
				let def_case_states = f ctx case_cond_states e in
				def_case_states :: case_states
		)
		in flatten rstates

	| _ -> fold_gexpr (f ctx) states e
	in f (1) states e


(*
   An algorithm to iterate over all possible execution paths (branches)
   one at a time. this is required, because the vast number of possible
   branches would make collecting the data we're interested in at once an extremely
   memory-hungry task. It's quite easy to end up with millions of possible execution
   paths per function, if we collect e.g. 1 KB of data per branch on average
   we'd require gigabytes of memory in total.

   there are additional considerations, that make iterating over the branches one at a time
   very interesting from a performance point of view. Because we only switch one single branch
   per step, most of the time we can reuse results for sequentially following branches.

   key is to transform the collected data EARLY to a dense representation of what we're really interested in.

    basic algorithm:

	consider a block that has the following toplevel branching instructions
	some of which have sub-branches, which combined are the number of 'deep' branches
	idx          no. toplevel | no. 'deep'
	0   if-else  2              2
	1   if-else  2              4
	2   switch   5              22
	3   if-else  2              2
	4   switch   6              6
	5   if-else  2              4
	------------------------------------------------------------
	                            8448 possible execution paths

	1. we start with the first branch of all branching instructions
	   - we collect our data for the first execution path
	2. we switch to the next branch in line, which means we set the
		if-else at idx 5 to the next path of the possible 4
	3. we repeat 2 until all 4 paths are exhausted
	4. we switch to the next branch, which means
	   current path+1
	     for the switch  at idx 4 and
	   0 for the if-else at idx 5
	5. we repeat 2. 3 and 4. until all paths are exhausted for idx 4,
	   and continue with idx 3,2,1 and 0 equivalently


   representation of a sequence of branching instructions

	branch_seq = {
		cur_idx  : int
		total    : int
		children : branch_instruction array
	}



   representation of if-else branches,representation of switches
   branch_instruction = {
		cur_idx  : int
		total    : int
		children : branch_instruction array
	}

   representation of for/while/do-while loops with break and continue


*)

let arrays_of_lists ll =
	Array.of_list (List.map ( fun l -> Array.of_list (List.rev l) ) ll)

let execution_paths_total seqs : int =
	let sum_seq seq = Array.fold_left (fun n bi -> (bi.gdb_total * n)) 1 seq in
	Array.fold_left ( fun n seq -> (sum_seq seq) + n ) 0 seqs

let iter_execution_paths_init e =
	let rec f ctx bins e : gdbranch_instruction_t list = match e.gexpr with
	| GIf (cond,e1,e2) ->
		let arrs,exprs = (match e2 with
		| Some e2 ->  [ (f ctx [] e1); (f ctx [] e2) ],[e1;e2]
		| None    ->  [ (f ctx [] e1) ],[e1]
	    ) in
	    let arrs  = arrays_of_lists arrs in
	    let total = (execution_paths_total arrs) in
		let bin = {
			gdb_idx   = 0;
			gdb_max   = 2;
			gdb_exprs = Array.of_list exprs;
			gdb_seq   = arrs;
			gdb_cur   = 0;
			gdb_total = total
		} in
		let _ = e.gdata <- GDBranchState bin in
		bin :: bins

	| GSwitch (cond,cases,def) ->
		let exprs = (match def with
		| Some def -> List.rev (def :: (List.rev_map (fun (_,e) -> e) cases))
		| None     -> List.map (fun (_,e) -> e) cases
		) in
		let arrs = arrays_of_lists (List.map (fun e -> (f ctx [] e)) exprs) in
		let total = (execution_paths_total arrs) in
		let bin = {
			gdb_idx   = 0;
			gdb_max   = Array.length arrs;
			gdb_exprs = Array.of_list exprs;
			gdb_seq   = arrs;
			gdb_cur   = 0;
			gdb_total = total
		} in
		let _ = e.gdata <- GDBranchState bin in
		bin :: bins
	| _ -> fold_gexpr (f ctx) bins e
	in
	let arrs    = arrays_of_lists [f (1) [] e] in
	let total   = (execution_paths_total arrs) in
	{
		gdb_idx   = 0;
		gdb_max   = 1;
		gdb_exprs = [||];
		gdb_seq   = arrs;
		gdb_cur   = 0;
		gdb_total = total
	}


type iter_res_t =
	| IterDone
	| IterCont



let iter_execution_paths_next it =
	let rec next it =
		let rec walk_seq seq idx = match idx with (*we walk a sequence of bins backwards *)
		| -1 -> IterDone  (*when we've finished the seq at index 0, we're done *)
		| _ ->
			let cur = seq.(idx) in
			(match next cur with (**)
				| IterCont -> IterCont (* branch instruction cur isn't exhausted yet *)
				| IterDone -> walk_seq seq (idx-1) (* step back to bin at idx-1 *)
			)
		in
		let cur_seq = it.gdb_seq.(it.gdb_idx ) in
		match ( walk_seq cur_seq ((Array.length cur_seq) - 1)) with
		| IterCont -> IterCont
		| IterDone -> (* we've exhausted a sequence belonging to a branch *)
			if (it.gdb_idx + 1 = it.gdb_max ) then (* we've also exhausted all branches*)
				let _ = it.gdb_idx <- 0 in (* reset *)
				IterDone
			else (*we have branches to process left *)
				let _ = it.gdb_idx <- it.gdb_idx + 1 in (* increase branch idx *)
				IterCont
	in next it



let dry_execution_path e =
	let rec f ctx acc e = match e.gdata,e.gexpr with
	| GDBranchState(bin), GIf (e,e1,e2) ->
		(match bin.gdb_idx with
			| 0 ->
				let acc = ( f ctx acc e1 ) in
				acc
			| 1 when (Array.length bin.gdb_exprs) > 1 ->
				let acc = (f ctx acc (bin.gdb_exprs.(1))) in
				acc
			| _ -> acc
		)
	| GDBranchState(bin), GSwitch (e,cases,def) ->
		let acc = (f ctx acc (bin.gdb_exprs.(bin.gdb_idx))) in
		acc
	| _, (GSwitch _ | GIf _) ->
		let _ = print_endline (s_gdata e.gdata ) in
		assert false
	| _ ->
		let acc = fold_gexpr (f ctx) acc e in acc
		(*((s_gexpr e)):: acc*)
	in
	let l = f (3,4) [] e in ()

let p_execution_path e =
	let rec f ctx acc e = match e.gdata,e.gexpr with
	| GDBranchState(bin), GIf (e,e1,e2) ->
		(match bin.gdb_idx with
			| 0 ->
				let acc = ( f ctx acc e1 ) in
				("if " ^ (string_of_int bin.gdb_idx)) :: acc
			| 1 when (Array.length bin.gdb_exprs) > 1 ->
				let acc = (f ctx acc (bin.gdb_exprs.(1))) in
				("else " ^ (string_of_int bin.gdb_idx)) :: acc
			| _ -> ("(else) " ^ (string_of_int bin.gdb_idx)) :: acc
		)
	| GDBranchState(bin), GSwitch (e,cases,def) ->
		let acc = (f ctx acc (bin.gdb_exprs.(bin.gdb_idx))) in
		("sw " ^ (string_of_int bin.gdb_idx)) :: acc
	| _, (GSwitch _ | GIf _) ->
		let _ = print_endline (s_gdata e.gdata ) in
		assert false
	| _ ->
		let acc = fold_gexpr (f ctx) acc e in acc
		(*((s_gexpr e)):: acc*)
	in
	let l = f (3,4) [] e in ()
	(*let s = String.concat ", " (List.rev l) in ()*)
	(*print_endline s*)

let exhaust it e =
	let rec loop n =
		(*let _ = p_execution_path e in*)
		let _ = dry_execution_path e in
		match iter_execution_paths_next it with
		| IterCont -> loop (n+1)
		| IterDone -> print_endline ("iter done, n: " ^ (string_of_int (n+1)))
	in loop 0


let eval_branches_2 states e =
	let rec f ctx states e : gr_state list = match e.gexpr with
	| GIf (e,e1,e2) ->
		let rstates = List.rev_map ( fun st->
			let cond_states = f ctx [st] e in
			let if_states   = f ctx cond_states e1 in (match e2 with
				| None ->
					flatten [cond_states;if_states]
				| Some e ->
					let else_states = f ctx cond_states e in
					flatten [if_states;else_states]
			)
		) states in
		flatten rstates
	| GSwitch (e,cases,def) ->
		let cond_states = f ctx states e in
		let case_cond_states,case_states = List.fold_left ( fun (states,rstates) (el,e2) ->
			let case_cond_states = eval_seq states (f ctx) el in
			let case_states      = f ctx case_cond_states e2 in
			(case_cond_states, case_states :: rstates)
		) (cond_states,[]) cases
		in
		let rstates = ( match def with
			| None -> case_states
			| Some e ->
				let def_case_states = f ctx case_cond_states e in
				def_case_states :: case_states
		)
		in flatten rstates

	| _ -> fold_gexpr (f ctx) states e
	in f (1) states e


(*let eval_gexpr f ctx e : gr_value = match e.gexpr with
	| GConst c -> (*(match c with
		| TInt v   -> GRInt v
		| TFloat v -> GRFloat v
		| TBool v  -> GRBool v
		| TNull    -> GRNull
		| TThis    -> ctx.gr_this
		| TSuper   -> ctx.gr_super
	)*) gr_null_val
	| GLocal v -> gr_null_val
	| GBreak
	| GContinue
	| GTypeExpr _ ->
		GRNull
	| GArray (e1,e2)
	| GBinop (_,e1,e2)
	| GFor (_,e1,e2)
	| GWhile (e1,e2,_) ->
		f e1;
		f e2;
	| GThrow e
	| GField (e,_)
	| GEnumParameter (e,_,_)
	| GParenthesis e
	| GCast (e,_)
	| GUnop (_,_,e)
	| GMeta(_,e) ->
		f e
	| GArrayDecl el
	| GNew (_,_,el)
	| GBlock el ->
		List.iter f el
	| GObjectDecl fl ->
		List.iter (fun (_,e) -> f e) fl
	| GCall (e,el) ->
		f e;
		List.iter f el
	| GVars vl ->
		List.iter (fun (_,e) -> match e with None -> gr_null_val | Some e -> f e) vl
	| GNVar v -> gr_null_val
	| GSVar (v, e) -> f e
	| GFunction (tf, e) ->
		f e

	| GIf (e,e1,e2) ->
		f e;
		f e1;
		(match e2 with None -> gr_null_val | Some e -> f e)

	| GSwitch (e,cases,def) ->
		f e;
		List.iter (fun (el,e2) -> List.iter f el; f e2) cases;
		(match def with None -> gr_null_val | Some e -> f e)
	| GPatMatch dt -> GRNull
	| GTry (e,catches) ->
		f e;
		List.iter (fun (_,e) -> f e) catches
	| GReturn eo ->
		(match eo with None -> GRNull | Some e -> f e)*)


(* ---------------------------------------------------------------------- *)






type blockinfogctx = {
	mutable blockid : int;
}
type blockinfoctx = {
	mutable blocks : gdata_t list;
}

let p_blockinfo xs =
	let rec loop depth x =
		match x with
		| GDBlockInfo (id,xs) ->
			print_endline ("block " ^ (string_of_int id) ^ " cs:" ^
				(String.concat "," (List.map ( fun d -> match d with
					| GDBlockInfo(id,_) -> (string_of_int id)
					| _ -> ""
				) xs )))
		| _ -> ()
	in
	List.iter (loop 0) xs

let s_type t = Type.s_type (print_context()) t
let s_types tl = String.concat ", " (List.map s_type tl)
let s_path (p,n) = (String.concat "." p) ^ "."  ^ n
let s_tparms xs = String.concat ", " (List.map (fun (s,t) -> (s ^ ":" ^(s_type t))) xs)

let s_class c =
    (s_path c.cl_path) ^ "<" ^ (s_tparms c.cl_types) ^">"
let p_call c cf el =
	let _ = print_endline ( "call " ^ (s_path c.cl_path) ^ "." ^ cf.cf_name ^"<"^ (s_tparms c.cl_types) ^">"^ (s_tparms cf.cf_params) ^ "" ) in
	let _ = print_endline (s_types (List.map (fun e -> e.gtype) el)) in
	let _ = (match cf.cf_type with
		| TFun (args,ret) ->
			let _ = print_endline (s_types (List.map (fun (_,_,t) -> t) args)) in ()
		| _ -> ()
		) in
	let _ = print_endline " --- " in
	()

let s_var v =
	(String.concat " " ["var";string_of_int v.v_id;v.v_name;s_type v.v_type])


let p_assign lhs rhs =
	let lhs = match lhs.gexpr with
	| GField (e1,(FInstance(c,cf)|FStatic(c,cf))) ->
		print_endline (String.concat " " ["assign to field:";s_class c;".";cf.cf_name;s_expr_kind e1.g_te;s_type e1.gtype])
	| GLocal v ->
		print_endline (String.concat " " ["assign to local:";string_of_int v.v_id;v.v_name;s_type v.v_type])
	|_ ->
		print_endline (String.concat " " [s_expr s_type lhs.g_te;"=";s_expr s_type rhs.g_te])
	in ()

let collect_block_info e =
	let rec f (gctx,ctx) e : gexpr_t = match e.gexpr with
	| GNew (c, [], el)   -> e
	| GNew (c, tl, el) ->
		let _ = print_endline ( "class " ^ (s_path c.cl_path) ^ "<" ^ (s_types tl) ^ ">" ) in
		let _ = Option.map (fun cf -> p_call c cf el) c.cl_constructor in
		e
	| GCall (e1, el) -> ( match e1.gexpr with
		| GField (_,(FInstance(c,cf)(*|FStatic(c,cf)*))) ->
			let _ = p_call c cf el in
			e
		| _ -> e
		)
	| GBlock el ->
		let _,nctx = (gctx,{ blocks = [] }) in
		let id = gctx.blockid in
		let _  = gctx.blockid <- id + 1 in
		let _ = List.map (f (gctx,nctx)) el in
		let data = GDBlockInfo (id, nctx.blocks ) in
		let _ = ctx.blocks <- data :: ctx.blocks in
		{ e with gdata = data }
	| GBinop (OpAssign,lhs,rhs) ->
			p_assign lhs rhs;
			e
	|_ -> map_gexpr (f (gctx,ctx)) e in
	let gctx,ctx = {blockid = 0},{blocks= []} in
	let _ = f (gctx,ctx) e in
	ctx.blocks

let gexpr_of_texpr e =
	let rec f e = match e.eexpr with
	_ -> map_expr f e
	in f e

let get_field_expressions xs = List.fold_left (fun acc cf ->
		match cf.cf_expr with
		| None -> acc
		| Some {eexpr = TFunction tf} -> tf.tf_expr :: acc
		| Some e -> e :: acc

	) [] xs
let get_fields_with_expressions xs = List.fold_left (fun acc cf ->
		match cf.cf_expr with
		| None -> acc
		| Some {eexpr = TFunction tf} -> (cf,gexpr_of_texpr tf.tf_expr) :: acc
		| Some e -> (cf,gexpr_of_texpr e) :: acc

	) [] xs

let run_analyzer ( mt : Type.module_type list ) : unit =
	print_endline "start";
	List.iter ( fun mt -> match mt with
	| TClassDecl v ->
		let fields  = List.map  gexpr_of_texpr (get_field_expressions v.cl_ordered_statics) in
		let statics = List.map  gexpr_of_texpr (get_field_expressions v.cl_ordered_fields) in
		(*let _ = List.iter (fun e -> p_blockinfo (collect_block_info e)) fields in*)
		let _,states = List.fold_left
			( fun (idx,acc) e -> (idx+1,eval_branches [{gst_id=idx}] e) ) (0,[]) fields in
		let _ = List.fold_left
			( fun idx (cf,e) ->
				if (snd v.cl_path) = "Branches" then begin

				let _ = print_endline ( ("================")) in
				let it = iter_execution_paths_init e in
				let _ = print_endline ( ("it: ") ^ (string_of_int (it.gdb_total))) in
				let _ = exhaust it e in
				(*
				let states = eval_branches [{gst_id=idx}] e in
				let _ = print_endline ( ("class: ") ^ s_path v.cl_path ) in
				let _ = print_endline ( ("field: ") ^ cf.cf_name ) in
				let _ = print_endline ("collected " ^ ( string_of_int (List.length states) ) ^ " states") in
				*)
				idx + 1
				end else idx+1
			)
			0
			(get_fields_with_expressions v.cl_ordered_fields) in
		(*let _ = print_endline ( ("class: ") ^ s_path v.cl_path ) in
		let _ = print_endline ("collected " ^ ( string_of_int (List.length states) ) ^ " states") in
		*)
		()
	| TEnumDecl  v -> ()
	| TTypeDecl  v -> ()
	| TAbstractDecl v -> ()
    ) mt;
	print_endline "done."
