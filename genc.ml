open Ast
open Common
open Type

type context = {
	com : Common.context;
	cvar : tvar;
	mutable num_temp_funcs : int;
	mutable num_labels : int;
	mutable num_anon_types : int;
	mutable anon_types : (string,string * tclass_field list) PMap.t;
}

type function_context = {
	field : tclass_field;
	expr : texpr option;
	mutable local_vars : tvar list;
	mutable loop_stack : string option list;
}

type type_context = {
	con : context;
	file_path_no_ext : string;
	buf_c : Buffer.t;
	buf_h : Buffer.t;
	mutable buf : Buffer.t;
	mutable tabs : string;
	mutable curpath : path;
	mutable fctx : function_context;
	mutable dependencies : (path,bool) PMap.t;
}

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
		curpath = path;
		fctx = {
			local_vars = [];
			field = null_field;
			expr = None;
			loop_stack = [];
		};
		dependencies = PMap.empty;
	}

let path_to_name (pack,name) = match pack with [] -> name | _ -> String.concat "_" pack ^ "_" ^ name
let path_to_header_path (pack,name) = match pack with [] -> name ^ ".h" | _ -> String.concat "/" pack ^ "/" ^ name ^ ".h"

let close_type_context ctx =
	let n = "_h" ^ path_to_name ctx.curpath in
	let ch_h = open_out_bin (ctx.file_path_no_ext ^ ".h") in
	print_endline ("Writing to " ^ (ctx.file_path_no_ext ^ ".h"));
	output_string ch_h ("#ifndef " ^ n ^ "\n");
	output_string ch_h ("#define " ^ n ^ "\n");
	output_string ch_h "#define GC_NOT_DLL\n";
	output_string ch_h "#include \"gc.h\"\n";
	output_string ch_h "#include \"glib/garray.h\"\n";
	let pabs = get_full_path ctx.con.com.file in
	PMap.iter (fun path _ ->
		output_string ch_h ("#include \"" ^ pabs ^ "/" ^ (path_to_header_path path) ^ "\"\n")
	) ctx.dependencies;
	output_string ch_h (Buffer.contents ctx.buf_h);
	output_string ch_h "\n#endif";
	close_out ch_h;

	let sc = Buffer.contents ctx.buf_c in
	if String.length sc > 0 then begin
		let ch_c = open_out_bin (ctx.file_path_no_ext ^ ".c") in
		output_string ch_c ("#include \"" ^ (snd ctx.curpath) ^ ".h\"\n");
		output_string ch_c sc;
		close_out ch_c
	end

let expr_debug ctx e =
	Printf.sprintf "%s: %s" ctx.fctx.field.cf_name (s_expr (s_type (print_context())) e)

let block e = match e.eexpr with
	| TBlock _ -> e
	| _ -> mk (TBlock [e]) e.etype e.epos

let begin_loop ctx =
	ctx.fctx.loop_stack <- None :: ctx.fctx.loop_stack;
	fun () ->
		match ctx.fctx.loop_stack with
		| ls :: l ->
			(match ls with None -> () | Some s -> print ctx "%s:" s);
			ctx.fctx.loop_stack <- l;
		| _ ->
			assert false

let mk_ccode ctx s =
	mk (TCall ((mk (TLocal ctx.con.cvar) t_dynamic Ast.null_pos), [mk (TConst (TString s)) t_dynamic Ast.null_pos])) t_dynamic Ast.null_pos

let full_field_name c cf = (path_to_name c.cl_path) ^ "_" ^ cf.cf_name
let full_enum_field_name en ef = (path_to_name en.e_path) ^ "_" ^ ef.ef_name

let add_dependency ctx path =
	if path <> ctx.curpath then ctx.dependencies <- PMap.add path true ctx.dependencies

let s_type ctx t = match follow t with
	| TAbstract({a_path = [],"Int"},[]) -> "int"
	| TAbstract({a_path = [],"Float"},[]) -> "double"
	| TAbstract({a_path = [],"Void"},[]) -> "void"
	| TInst({cl_path = [],"String"},[]) -> "char*"
	| TInst({cl_path = [],"Array"},[_]) -> "GArray*"
	| TInst({cl_kind = KTypeParameter _},_) -> "void*"
	| TInst(c,_) ->
		add_dependency ctx c.cl_path;
		(path_to_name c.cl_path) ^ "*"
	| TEnum(en,_) ->
		add_dependency ctx en.e_path;
		(path_to_name en.e_path) ^ "*"
	| TAnon a ->
		begin match !(a.a_status) with
		| Statics c -> "Class_" ^ (path_to_name c.cl_path) ^ "*"
		| EnumStatics en -> "Enum_" ^ (path_to_name en.e_path) ^ "*"
		| AbstractStatics a -> "Anon_" ^ (path_to_name a.a_path) ^ "*"
		| _ ->
			add_dependency ctx (["hxc"],"AnonTypes");
			let fields = PMap.fold (fun cf acc -> cf :: acc) a.a_fields [] in
			let fields = List.sort (fun cf1 cf2 -> compare cf1.cf_name cf2.cf_name) fields in
			let id = String.concat "," (List.map (fun cf -> cf.cf_name ^ (s_type (print_context()) cf.cf_type)) fields) in
			let s = begin
				try fst (PMap.find id ctx.con.anon_types)
				with Not_found ->
					ctx.con.num_anon_types <- ctx.con.num_anon_types + 1;
					let s = "_hx_anon_" ^ (string_of_int ctx.con.num_anon_types) in
					ctx.con.anon_types <- PMap.add id (s,fields) ctx.con.anon_types;
					s
			end in
			s ^ "*"
		end
	| _ -> "void*"

let monofy_class c = TInst(c,List.map (fun _ -> mk_mono()) c.cl_types)

let declare_var ctx v = if not (List.mem v ctx.local_vars) then ctx.local_vars <- v :: ctx.local_vars

let rec generate_expr ctx e = match e.eexpr with
	| TBlock([]) ->
		spr ctx "{ }"
	| TBlock(el) ->
		spr ctx "{";
		let b = open_block ctx in
		List.iter (fun e ->
			newline ctx;
			generate_expr ctx e;
		) el;
		b();
		newline ctx;
		spr ctx "}";
		newline ctx;
	| TConst(TString s) ->
		print ctx "\"%s\"" s
	| TConst(TInt i) ->
		print ctx "%ld" i
	| TConst(TFloat s) ->
		print ctx "%sd" s
	| TConst(TNull) ->
		spr ctx "NULL"
	| TConst(TSuper) ->
		(* TODO: uhm... *)
		()
	| TConst(TBool true) ->
		spr ctx "TRUE"
	| TConst(TBool false) ->
		spr ctx "FALSE"
	| TConst(TThis) ->
		spr ctx "this"
	| TCall({eexpr = TLocal({v_name = "__trace"})},[e1]) ->
		spr ctx "printf(\"%s\\n\",";
		generate_expr ctx e1;
		spr ctx ")";
	| TCall({eexpr = TLocal({v_name = "__c"})},[{eexpr = TConst(TString code)}]) ->
		spr ctx code
	| TCall({eexpr = TField(e1,FInstance(c,cf))},el) ->
		add_dependency ctx c.cl_path;
		spr ctx (full_field_name c cf);
		spr ctx "(";
		generate_expr ctx e1;
		List.iter (fun e ->
			spr ctx ",";
			generate_expr ctx e
		) el;
		spr ctx ")"
	| TCall({eexpr = TField(_,FEnum(en,ef))},el) ->
		print ctx "new_%s(" (full_enum_field_name en ef);
		concat ctx "," (generate_expr ctx) el;
		spr ctx ")"
	| TCall(e1, el) ->
		generate_expr ctx e1;
		spr ctx "(";
		concat ctx "," (generate_expr ctx) el;
		spr ctx ")"
	| TTypeExpr (TClassDecl c) ->
		spr ctx (path_to_name c.cl_path);
	| TTypeExpr (TEnumDecl e) ->
		spr ctx (path_to_name e.e_path);
	| TTypeExpr (TTypeDecl _ | TAbstractDecl _) ->
		(* shouldn't happen? *)
		assert false
	| TField(_,FStatic(c,cf)) ->
		add_dependency ctx c.cl_path;
		spr ctx (full_field_name c cf)
	| TField(_,FEnum(en,ef)) ->
		print ctx "new_%s()" (full_enum_field_name en ef)
	| TField(e1,fa) ->
		let n = field_name fa in
		spr ctx "(";
		generate_expr ctx e1;
		print ctx ")->%s" n
	| TLocal v ->
		spr ctx v.v_name;
	| TObjectDecl _ ->
		spr ctx "0";
	| TNew(c,_,el) ->
		add_dependency ctx c.cl_path;
		spr ctx (full_field_name c (match c.cl_constructor with None -> assert false | Some cf -> cf));
		spr ctx "(";
		concat ctx "," (generate_expr ctx) el;
		spr ctx ")";
	| TReturn None ->
		spr ctx "return"
	| TReturn (Some e1) ->
		spr ctx "return (";
		generate_expr ctx e1;
		spr ctx ")"
	| TBinop(OpAssign, e1, e2) ->
		generate_expr ctx e1;
		spr ctx " = ";
		generate_expr ctx e2;
	| TVars(vl) ->
		let f (v,eo) =
			print ctx "%s %s" (s_type ctx v.v_type) v.v_name;
			begin match eo with
				| None -> ()
				| Some e ->
					spr ctx " = ";
					generate_expr ctx e;
			end
		in
		concat ctx ";" f vl
	| TArray(e1,e2) ->
		spr ctx "g_array_index(";
		generate_expr ctx e1;
		spr ctx ",";
		spr ctx (s_type ctx e.etype);
		spr ctx ",";
		generate_expr ctx e2;
		spr ctx ")";
	| TWhile(e1,e2,NormalWhile) ->
		spr ctx "while";
		generate_expr ctx e1;
		let l = begin_loop ctx in
		generate_expr ctx (block e2);
		l()
	| TWhile(e1,e2,DoWhile) ->
		spr ctx "do";
		let l = begin_loop ctx in
		generate_expr ctx (block e2);
		spr ctx " while";
		generate_expr ctx e1;
		l()
	| TContinue ->
		spr ctx "continue";
	| TBreak _ ->
		let label = match ctx.fctx.loop_stack with
			| (Some s) :: _ -> s
			| None :: l ->
				let s = Printf.sprintf "_hx_label%i" ctx.con.num_labels in
				ctx.con.num_labels <- ctx.con.num_labels + 1;
				ctx.fctx.loop_stack <- (Some s) :: l;
				s
			| [] ->
				assert false
		in
		print ctx "goto %s" label;
	| TIf(e1,e2,e3) ->
		spr ctx "if";
		generate_expr ctx e1;
		generate_expr ctx (block e2);
		(match e3 with None -> () | Some e3 ->
			spr ctx " else ";
			generate_expr ctx (block e3))
	| TSwitch(e1,cases,edef) ->
		spr ctx "switch";
		generate_expr ctx e1;
		spr ctx "{";
		let generate_case_expr e =
			let b = open_block ctx in
			List.iter (fun e ->
				newline ctx;
				generate_expr ctx e;
			) (match e.eexpr with TBlock el -> el | _ -> [e]);
			newline ctx;
			spr ctx "break";
			b();
		in
		let b = open_block ctx in
		newline ctx;
		List.iter (fun (el,e) ->
			spr ctx "case ";
			concat ctx "," (generate_expr ctx) el;
			spr ctx ":";
			generate_case_expr e;
			newline ctx;
		) cases;
		begin match edef with
			| None -> ()
			| Some e ->
				spr ctx "default:";
				generate_case_expr e;
		end;
		b();
		newline ctx;
		spr ctx "}";
	| TBinop(op,e1,e2) ->
		generate_expr ctx e1;
		print ctx " %s " (s_binop op);
		generate_expr ctx e2;
	| TUnop(op,Prefix,e1) ->
		spr ctx (s_unop op);
		generate_expr ctx e1;
	| TUnop(op,Postfix,e1) ->
		generate_expr ctx e1;
		spr ctx (s_unop op);
	| TParenthesis e1 ->
		spr ctx "(";
		generate_expr ctx e1;
		spr ctx ")";
	| TArrayDecl _ ->
		(* handled in function context pass *)
		assert false
	| TMeta(_,e) ->
		generate_expr ctx e
	| TCast(e,_) ->
		(* TODO: make this do something *)
		generate_expr ctx e
	| TEnumParameter (e1,ef,i) ->
		generate_expr ctx e1;
		begin match follow e1.etype with
			| TEnum(en,_) ->
				let s,_,_ = match ef.ef_type with TFun(args,_) -> List.nth args i | _ -> assert false in
				print ctx "->args.%s.%s" ef.ef_name s;
			| _ ->
				assert false
		end
	| TThrow _
	| TTry _
	| TPatMatch _
	| TFor _
	| TFunction _ ->
		print_endline ("Not implemented yet: " ^ (expr_debug ctx e))

let mk_array_decl ctx el t p =
	let ts = match follow t with
		| TInst(_,[t]) -> s_type ctx t
		| _ -> assert false
	in
	let name = "_hx_func_" ^ (string_of_int ctx.con.num_temp_funcs) in
	let arity = List.length el in
	print ctx "GArray* %s(%s) {" name (String.concat "," (ExtList.List.mapi (fun i e -> Printf.sprintf "%s v%i" (s_type ctx e.etype) i) el));
	ctx.con.num_temp_funcs <- ctx.con.num_temp_funcs + 1;
	let bl = open_block ctx in
	newline ctx;
	print ctx "GArray* garray = g_array_sized_new(FALSE, FALSE, sizeof(%s), %i)" ts arity;
	newline ctx;
	ExtList.List.iteri (fun i e ->
		print ctx "g_array_append_val(garray, v%i)" i;
		newline ctx;
	) el;
	spr ctx "return garray";
	bl();
	newline ctx;
	spr ctx "}";
	newline ctx;
	let v = alloc_var name t_dynamic in
	let ev = mk (TLocal v) v.v_type p in
	mk (TCall(ev,el)) t p

let mk_function_context ctx cf =
	let locals = ref [] in
	let rec loop e = match e.eexpr with
		| TVars vl ->
			let el = ExtList.List.filter_map (fun (v,eo) ->
				locals := v :: !locals;
				match eo with
				| None -> None
				| Some e -> Some (mk (TBinop(OpAssign, mk (TLocal v) v.v_type e.epos,loop e)) e.etype e.epos)
			) vl in
			begin match el with
			| [e] -> e
			| _ -> mk (TBlock el) ctx.con.com.basic.tvoid e.epos
			end
		| TArrayDecl el ->
			mk_array_decl ctx el e.etype e.epos
		| _ -> Type.map_expr loop e
	in
	let e = match cf.cf_expr with
		| None -> None
		| Some e -> Some (loop e)
	in
	{
		field = cf;
		local_vars = !locals;
		expr = e;
		loop_stack = [];
	}

let generate_function_header ctx c cf =
	let args,ret = match follow cf.cf_type with
		| TFun(args,ret) -> args,ret
		| _ -> assert false
	in
	print ctx "%s %s(%s)" (s_type ctx ret) (full_field_name c cf) (String.concat "," (List.map (fun (n,_,t) -> Printf.sprintf "%s %s" (s_type ctx t) n) args))

let generate_method ctx c cf =
	ctx.fctx <- mk_function_context ctx cf;
	generate_function_header ctx c cf;
	match ctx.fctx.expr with
	| None -> newline ctx
	| Some {eexpr = TFunction ({tf_expr = {eexpr = TBlock el}; tf_type = t})} ->
		let el = match ctx.fctx.local_vars with
			| [] -> el
			| _ ->
				let einit = mk (TVars (List.map (fun v -> v,None) ctx.fctx.local_vars)) ctx.con.com.basic.tvoid cf.cf_pos in
				einit :: el
		in
		let e = mk (TBlock el) t cf.cf_pos in
		generate_expr ctx e
	| _ -> assert false

let generate_class ctx c =
	(* split fields into member vars, static vars and functions *)
	let vars = DynArray.create () in
	let svars = DynArray.create () in
	let methods = DynArray.create () in
	List.iter (fun cf -> match cf.cf_kind with
		| Var _ -> DynArray.add vars cf
		| Method _ -> match cf.cf_type with
			| TFun(args,ret) ->
				cf.cf_type <- TFun(("this",false,monofy_class c) :: args, ret);
				DynArray.add methods cf
			| _ ->
				assert false;
	) c.cl_ordered_fields;
	List.iter (fun cf -> match cf.cf_kind with
		| Var _ -> DynArray.add svars cf
		| Method _ -> DynArray.add methods cf
	) c.cl_ordered_statics;

	begin match c.cl_constructor with
		| None -> ()
		| Some cf -> match follow cf.cf_type, cf.cf_expr with
			| TFun(args,_), Some e ->
				let path = path_to_name c.cl_path in
				let einit = mk_ccode ctx (Printf.sprintf "%s* this = (%s*) GC_MALLOC(sizeof(%s))" path path path) in
				let ereturn = mk_ccode ctx "return this" in
				let e = match e.eexpr with
					| TFunction({tf_expr = ({eexpr = TBlock el } as ef) } as tf) ->
						{e with eexpr = TFunction ({tf with tf_expr = {ef with eexpr = TBlock(einit :: el @ [ereturn])}})}
					| _ -> assert false
				in
				cf.cf_expr <- Some e;
				cf.cf_type <- TFun(args, monofy_class c);
				DynArray.add methods cf
			| _ -> ()
	end;

	ctx.buf <- ctx.buf_c;

	(* generate function implementations *)
	if not (DynArray.empty methods) then begin
		DynArray.iter (fun cf ->
			generate_method ctx c cf;
		) methods;
	end;

	ctx.buf <- ctx.buf_h;

	(* generate member struct *)
	if not (DynArray.empty vars) then begin
		spr ctx "// member var structure\n";
		print ctx "typedef struct %s {" (path_to_name c.cl_path);
		let b = open_block ctx in
		DynArray.iter (fun cf ->
			newline ctx;
			print ctx "%s %s" (s_type ctx cf.cf_type) cf.cf_name;
		) vars;
		b();
		newline ctx;
		print ctx "} %s" (path_to_name c.cl_path);
		newline ctx;
		spr ctx "\n";
	end;

	(* generate static vars *)
	if not (DynArray.empty svars) then begin
		spr ctx "// static vars\n";
		DynArray.iter (fun cf ->
			print ctx "%s %s" (s_type ctx cf.cf_type) (full_field_name c cf);
			match cf.cf_expr with
			| None -> newline ctx
			| Some e ->
				spr ctx " = ";
				generate_expr ctx e;
				newline ctx
		) svars;
	end;

	(* generate forward declarations of functions *)
	if not (DynArray.empty methods) then begin
		spr ctx "// forward declarations\n";
		DynArray.iter (fun cf ->
			generate_function_header ctx c cf;
			newline ctx;
		) methods;
	end;

	(* check if we have the main class *)
	match ctx.con.com.main_class with
	| Some path when path = c.cl_path ->
		print ctx "int main() {\n\tGC_INIT();\n\t%s();\n}" (full_field_name c (PMap.find "main" c.cl_statics))
	| _ -> ()

let generate_enum ctx en =
	ctx.buf <- ctx.buf_h;
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
			spr ctx "typedef struct {";
			let b = open_block ctx in
			List.iter (fun (n,_,t) ->
				newline ctx;
				print ctx "%s %s" (s_type ctx t) n;
			) args;
			b();
			newline ctx;
			print ctx "} %s" (full_enum_field_name en ef);
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

	(* generate constructor functions *)
	spr ctx "// constructor functions";
	List.iter (fun ef ->
		newline ctx;
		match ef.ef_type with
		| TFun(args,ret) ->
			print ctx "%s new_%s(%s) {" (s_type ctx ret) (full_enum_field_name en ef) (String.concat "," (List.map (fun (n,_,t) -> Printf.sprintf "%s %s" (s_type ctx t) n) args));
			let b = open_block ctx in
			newline ctx;
			print ctx "%s* this = (%s*) GC_MALLOC(sizeof(%s))" path path path;
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
	| TClassDecl c when not c.cl_extern ->
		let ctx = mk_type_context con c.cl_path in
		generate_class ctx c;
		close_type_context ctx;
	| TEnumDecl en when not en.e_extern ->
		let ctx = mk_type_context con en.e_path in
		generate_enum ctx en;
		close_type_context ctx;
	| _ ->
		()

let generate_hxc_files con =
	let ctx = mk_type_context con (["hxc"],"AnonTypes") in
	spr ctx "// Anonymous types";
	PMap.iter (fun _ (s,cfl) ->
		newline ctx;
		print ctx "typedef struct %s {" s;
		let b = open_block ctx in
		List.iter (fun cf ->
			newline ctx;
			print ctx "%s %s" (s_type ctx cf.cf_type) cf.cf_name;
		) cfl;
		b();
		newline ctx;
		print ctx "} %s" s;
	) con.anon_types;
	newline ctx;
	close_type_context ctx

let generate com =
	let con = {
		com = com;
		cvar = alloc_var "__c" t_dynamic;
		num_temp_funcs = 0;
		num_labels = 0;
		num_anon_types = -1;
		anon_types = PMap.empty;
	} in
	List.iter (generate_type con) com.types;
	generate_hxc_files con