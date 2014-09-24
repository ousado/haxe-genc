open Ast
open Type
open Common

let s_expr = s_expr (s_type (print_context()))
let s_expr_pretty = s_expr_pretty "" (s_type (print_context()))
let debug e = if e.epos.pfile = "src/Main.hx" then print_endline (s_expr e)

let has_analyzer_option meta s =
	try
		let _,el,_ = Meta.get Meta.Analyzer meta in
		List.exists (fun (e,p) ->
			match e with
				| EConst(Ident s2) when s = s2 -> true
				| _ -> false
		) el
	with Not_found ->
		false

let rec get_type_meta t = match t with
	| TMono r ->
		begin match !r with
			| None -> raise Not_found
			| Some t -> get_type_meta t
		end
	| TLazy f ->
		get_type_meta (!f())
	| TInst(c,_) ->
		c.cl_meta
	| TEnum(en,_) ->
		en.e_meta
	| TAbstract(a,_) ->
		a.a_meta
	| TType(t,_) ->
		t.t_meta
	| TAnon _ | TFun _ | TDynamic _ ->
		raise Not_found

let type_has_analyzer_option t s =
	try
		has_analyzer_option (get_type_meta t) s
	with Not_found ->
		false

(*
	This module simplifies the AST by introducing temporary variables for complex expressions in many places.
	In particular, it ensures that no branching can occur in value-places so that we can later insert SSA PHI
	nodes without worrying about their placement.
*)
module Simplifier = struct
	let mk_block_context com gen_temp =
		let block_el = ref [] in
		let push e = block_el := e :: !block_el in
		let assign ev e =
			(* debug e; *)
			let mk_assign e2 = match e2.eexpr with
				| TBreak | TContinue | TThrow _ -> e2
				| _ -> mk (TBinop(OpAssign,ev,e2)) e2.etype e2.epos
			in
			let rec loop e = match e.eexpr with
				| TBlock el ->
					begin match List.rev el with
						| e1 :: el ->
							let el = List.rev ((loop e1) :: el) in
							{e with eexpr = TBlock el}
						| _ ->
							mk_assign e
					end
				| TIf(e1,e2,eo) ->
					let e2 = loop e2 in
					let eo = match eo with None -> None | Some e3 -> Some (loop e3) in
					{e with eexpr = TIf(e1,e2,eo)}
				| TSwitch(e1,cases,edef) ->
					let cases = List.map (fun (el,e) ->
						let e = loop e in
						el,e
					) cases in
					let edef = match edef with None -> None | Some edef -> Some (loop edef) in
					{e with eexpr = TSwitch(e1,cases,edef)}
(* 				| TBinop(OpAssign,({eexpr = TLocal _} as e1),e2) ->
					push e;
					mk_assign e1 *)
(* 				| TBinop(OpAssignOp op,({eexpr = TLocal _} as e1),e2) ->
					push e;
					mk_assign e1 *)
				| TParenthesis e1 | TMeta(_, e1) ->
					loop e1 (* this is weird *)
				| _ ->
					mk_assign e
			in
			loop e
		in
		let declare_temp t eo p =
			let v = gen_temp t in
			v.v_id <- -v.v_id;
			let e_v = mk (TLocal v) t p in
			let declare e_init =
				let e = mk (TVar (v,e_init)) com.basic.tvoid p in
				push e;
			in
			begin match eo with
				| None ->
					declare None
				| Some e1 ->
					begin match e1.eexpr with
						| TThrow _ | TReturn _ | TBreak | TContinue ->
							()
						| _ ->
							let e1 = assign e_v e1 in
							begin match e1.eexpr with
								| TBinop(OpAssign,{eexpr = TLocal v1},e2) when v == v1 ->
									declare (Some e2)
								| _ ->
									declare None;
									push e1
							end
					end
			end;
			e_v
		in
		let rec push_block () =
			let cur = !block_el in
			block_el := [];
			fun () ->
				let added = !block_el in
				block_el := cur;
				List.rev added
		and block f el =
			let close = push_block() in
			List.iter (fun e ->
				push (f e)
			) el;
			close()
		in
		block,declare_temp,fun () -> !block_el

	let apply com gen_temp e =
		let block,declare_temp,close_block = mk_block_context com gen_temp in
		let skip_binding ?(allow_tlocal=false) e =
			let rec loop e =
				match e.eexpr with
				| TConst _ | TTypeExpr _ | TFunction _ -> ()
				| TLocal _ when allow_tlocal -> ()
				| TParenthesis e1 | TCast(e1,None) | TEnumParameter(e1,_,_) -> Type.iter loop e
				| TField(_,(FStatic(c,cf) | FInstance(c,_,cf))) when has_analyzer_option cf.cf_meta "no_simplification" || has_analyzer_option c.cl_meta "no_simplification" -> ()
				| _ -> raise Exit
			in
			try
				loop e;
				true
			with Exit ->
				begin match follow e.etype with
					| TAbstract({a_path = [],"Void"},_) -> true
					| _ -> false
				end
		in
		let rec loop e = match e.eexpr with
			| TLocal v when Meta.has Meta.Unbound v.v_meta && v.v_name <> "`trace" ->
				raise Exit (* nope *)
			| TBlock el ->
				{e with eexpr = TBlock (block loop el)}
			| TCall({eexpr = TField(_,(FStatic(c,cf) | FInstance(c,_,cf)))},el) when has_analyzer_option cf.cf_meta "no_simplification" || has_analyzer_option c.cl_meta "no_simplification" ->
				e
			| TField(_,(FStatic(c,cf) | FInstance(c,_,cf))) when has_analyzer_option cf.cf_meta "no_simplification" || has_analyzer_option c.cl_meta "no_simplification" ->
				e
			| TCall(e1,el) ->
				let e1 = loop e1 in
				let check e t =
					if type_has_analyzer_option t "no_simplification" then e
					else bind e
				in
				let el = match e1.eexpr,follow e1.etype with
					| TConst TSuper,_ when com.platform = Java || com.platform = Cs ->
						(* they hate you if you mess up the super call *)
						el
					| _,TFun _ ->
						Codegen.UnificationCallback.check_call check el e1.etype
					| _ ->
						(* too dangerous *)
						List.map loop el
				in
				{e with eexpr = TCall(e1,el)}
			| TNew(c,tl,el) ->
				{e with eexpr = TNew(c,tl,ordered_list el)}
			| TArrayDecl el ->
				{e with eexpr = TArrayDecl (ordered_list el)}
			| TObjectDecl fl ->
				let el = ordered_list (List.map snd fl) in
				{e with eexpr = TObjectDecl (List.map2 (fun (n,_) e -> n,e) fl el)}
			| TBinop(OpBoolAnd | OpBoolOr as op,e1,e2) ->
				let e1 = loop e1 in
				let e_then = mk (TBlock (block loop [e2])) e2.etype e2.epos in
				let e_if,e_else = if op = OpBoolOr then
					mk (TUnop(Not,Prefix,e1)) com.basic.tbool e.epos,mk (TConst (TBool(true))) com.basic.tbool e.epos
				else
					e1,mk (TConst (TBool(false))) com.basic.tbool e.epos
				in
				loop (mk (TIf(e_if,e_then,Some e_else)) com.basic.tbool e.epos)
			| TBinop((OpAssign | OpAssignOp _) as op,{eexpr = TArray(e11,e12)},e2) ->
				let e1 = match ordered_list [e11;e12] with
					| [e1;e2] ->
						{e with eexpr = TArray(e1,e2)}
					| _ ->
						assert false
				in
				let e2 = loop e2 in
				{e with eexpr = TBinop(op,e1,e2)}
			| TBinop((OpAssign | OpAssignOp _) as op,e1,e2) ->
				let e2 = bind e2 in
				let e1 = loop e1 in
				{e with eexpr = TBinop(op,e1,e2)}
			| TBinop(op,e1,e2) ->
				begin match ordered_list [e1;e2] with
					| [e1;e2] ->
						{e with eexpr = TBinop(op,e1,e2)}
					| _ ->
						assert false
				end
			| TArray(e1,e2) ->
				begin match ordered_list [e1;e2] with
					| [e1;e2] ->
						{e with eexpr = TArray(e1,e2)}
					| _ ->
						assert false
				end
			| TWhile(e1,e2,flag) when (match e1.eexpr with TParenthesis {eexpr = TConst(TBool true)} -> false | _ -> true) ->
				let p = e.epos in
				let e_break = mk TBreak t_dynamic p in
				let e_not = mk (TUnop(Not,Prefix,Codegen.mk_parent e1)) e1.etype e1.epos in
				let e_if eo = mk (TIf(e_not,e_break,eo)) com.basic.tvoid p in
				let rec map_continue e = match e.eexpr with
					| TContinue ->
						(e_if (Some e))
					| TWhile _ | TFor _ ->
						e
					| _ ->
						Type.map_expr map_continue e
				in
				let e2 = if flag = NormalWhile then e2 else map_continue e2 in
				let e_if = e_if None in
				let e_block = if flag = NormalWhile then Type.concat e_if e2 else Type.concat e2 e_if in
				let e_true = mk (TConst (TBool true)) com.basic.tbool p in
				let e = mk (TWhile(Codegen.mk_parent e_true,e_block,NormalWhile)) e.etype p in
				loop e
			| TFor(v,e1,e2) ->
				let e1 = bind e1 in
				let e2 = loop e2 in
				{e with eexpr = TFor(v,e1,e2)}
			| TIf(e1,e2,eo) ->
				let e1 = bind e1 in
				let e2 = loop e2 in
				let eo = match eo with None -> None | Some e -> Some (loop e) in
				{e with eexpr = TIf(e1,e2,eo)}
			| TVar(v,Some e1) ->
				let e1 = match e1.eexpr with
					| TFunction _ -> loop e1
					| TArrayDecl [{eexpr = TFunction _}] -> loop e1
					| _ -> bind e1
				in
				{e with eexpr = TVar(v,Some e1)}
			| TUnop((Neg | NegBits | Not) as op,flag,e1) ->
				let e1 = bind e1 in
				{e with eexpr = TUnop(op,flag,e1)}
			| TField(e1,fa) ->
				let e1 = bind e1 in
				{e with eexpr = TField(e1,fa)}
			| TReturn (Some ({eexpr = TThrow _ | TReturn _} as e1)) ->
				loop e1 (* this is a bit hackish *)
			| TReturn (Some e1) ->
				let e1 = bind e1 in
				{e with eexpr = TReturn (Some e1)}
			| TCast(e1,mto) ->
				let e1 = bind ~allow_tlocal:true e1 in
				{e with eexpr = TCast(e1,mto)}
			| _ ->
				Type.map_expr loop e
		and bind ?(allow_tlocal=false) e =
			let e = loop e in
			if skip_binding ~allow_tlocal e then
				e
			else
				declare_temp e.etype (Some e) e.epos
		and ordered_list el =
			if List.for_all (skip_binding ~allow_tlocal:true) el then
				List.map loop el
			else
				List.map bind el
		in
		let e = loop e in
		match close_block() with
			| [] ->
				e
			| el ->
				mk (TBlock (List.rev (e :: el))) e.etype e.epos

	let unapply e =
		let var_map = ref PMap.empty in
		let rec loop e = match e.eexpr with
			| TBlock el ->
				let el = ExtList.List.filter_map (fun e -> match e.eexpr with
					| TVar(v,Some e1) when v.v_id < 0 ->
						var_map := PMap.add v.v_id (loop e1) !var_map;
						None
					| _ ->
						Some (loop e)
				) el in
				{e with eexpr = TBlock el}
			| TLocal v when v.v_id < 0 ->
				begin try PMap.find v.v_id !var_map
				with Not_found -> e end
			| _ ->
				Type.map_expr loop e
		in
		loop e
end

module Ssa = struct

	type var_map = ((int,tvar) PMap.t)

	type join_node = {
		mutable branches : var_map list;
	}

	type ssa_context = {
		com : Common.context;
		mutable cleanup : (unit -> unit) list;
		mutable cur_vars : (int,tvar) PMap.t;
		mutable loop_stack : (join_node * join_node) list;
		mutable exception_stack : join_node list;
		mutable var_values : (int,texpr) PMap.t;
	}

	let mk_phi =
		let v_phi = alloc_var "__ssa_phi__" t_dynamic in
		(fun vl p ->
			let mk_loc v = mk (TLocal v) v.v_type p in
			let e = mk (TCall(mk_loc v_phi,(List.map mk_loc vl))) t_dynamic p in
			e
		)

	let invert_phi phi =
		List.fold_left (fun acc (v,vl) -> match List.rev vl with
			| [] -> acc
			| v2 :: _ -> PMap.add v2.v_id v acc
		) PMap.empty phi

	let replace_locals phi_inv e =
		let rec loop e = match e.eexpr with
			| TLocal v ->
				begin try
					{e with eexpr = TLocal (PMap.find v.v_id phi_inv)}
				with Not_found ->
					e
				end
			| _ ->
				Type.map_expr loop e
		in
		loop e

	let replace_vars phi_inv vars =
		PMap.mapi (fun i v ->
			try
				let v' = PMap.find v.v_id phi_inv in
				v'
			with Not_found -> v
		) vars

	let build_phi vl p =
		List.map (fun (v,vl) ->
			let phi = mk_phi vl p in
			let e = Codegen.binop OpAssign (mk (TLocal v) v.v_type p) phi phi.etype p in
			mk (TMeta((Meta.Custom ":ssa",[],e.epos),e)) e.etype e.epos
		) vl

	let to_block el t p =
		mk (TBlock el) t p

	let mk_loc v = mk (TLocal v) v.v_type null_pos

	(* TODO: make sure this is conservative *)
	let can_throw e =
		let rec loop e = match e.eexpr with
			| TConst _ | TLocal _ | TTypeExpr _ | TFunction _ -> ()
			| TCall _ | TNew _ | TThrow _ | TCast(_,Some _) -> raise Exit
			| _ -> Type.iter loop e
		in
		try
			loop e; false
		with Exit ->
			true

	let append_phi e phi = match phi with
		| [] ->
			e
		| _ ->
			let e_phi = to_block (build_phi phi e.epos) e.etype e.epos in
			concat e e_phi

	let mk_join_node() = {
		branches = []
	}

	let add_vars join vars =
		join.branches <- vars :: join.branches

	let branch ctx =
		let old = ctx.cur_vars in
		(fun join ->
			add_vars join ctx.cur_vars;
			ctx.cur_vars <- old
		)

	let set_loop_join ctx join_top join_bottom =
		ctx.loop_stack <- (join_top,join_bottom) :: ctx.loop_stack;
		(fun () ->
			ctx.loop_stack <- List.tl ctx.loop_stack
		)

	let set_exception_join ctx join =
		ctx.exception_stack <- join :: ctx.exception_stack;
		(fun () ->
			ctx.exception_stack <- List.tl ctx.exception_stack;
		)

	let declare_var ctx v =
		let old = v.v_extra in
		ctx.cleanup <- (fun () ->
			v.v_extra <- old
		) :: ctx.cleanup;
		ctx.cur_vars <- PMap.add v.v_id v ctx.cur_vars;
		v.v_extra <- Some ([],(Some (mk_loc v)))

	let assign_var ctx v e p =
		if v.v_capture then
			v
		else begin
			let i = match v.v_extra with
				| Some (l,eo) ->
					v.v_extra <- Some (("",t_dynamic) :: l,eo);
					List.length l + 1
				| _ ->
					assert false
			in
			let v' = alloc_var (Printf.sprintf "%s<%i>" v.v_name i) v.v_type in
			v'.v_meta <- [(Meta.Custom ":ssa"),[],p];
			v'.v_extra <- Some ([],(Some (mk_loc v)));
			ctx.cur_vars <- PMap.add v.v_id v' ctx.cur_vars;
			ctx.var_values <- PMap.add v'.v_id e ctx.var_values;
			(* if p.pfile = "src/Main.hx" then Printf.printf "%s (%i) = %s\n" v'.v_name v'.v_id (s_expr_pretty e); *)
			v'
		end

	let get_var ctx v p =
		try
			PMap.find v.v_id ctx.cur_vars
		with Not_found ->
			ctx.com.warning (Printf.sprintf "Unbound variable %s (is_unbound: %b)" v.v_name (has_meta Meta.Unbound v.v_meta)) p;
			v

	let close_join_node ctx node p =
		let vars = ref PMap.empty in
		let rec handle_branch branch =
			PMap.iter (fun i v ->
				try
					let vl = PMap.find i !vars in
					if not (List.memq v vl) then
						vars := PMap.add i (v :: vl) !vars
				with Not_found ->
					vars := PMap.add i [v] !vars
			) branch;
		in
		List.iter handle_branch node.branches;
		PMap.foldi (fun i vl acc -> match vl with
			| [v] ->
				ctx.cur_vars <- PMap.add i v ctx.cur_vars;
				acc
			| {v_extra = Some (_,Some {eexpr = TLocal v})} :: _ ->
				let v' = assign_var ctx v (mk_phi vl null_pos) p in
				((v',vl) :: acc)
			| _ ->
				assert false
		) !vars []

	let apply com e =
		let rec handle_if ctx e econd eif eelse =
			let econd = loop ctx econd in
			let join = mk_join_node() in
			let close = branch ctx in
			let eif = loop ctx eif in
			close join;
			let eelse = match eelse with
				| None ->
					add_vars join ctx.cur_vars;
					None
				| Some e ->
					let close = branch ctx in
					let eelse = loop ctx e in
					close join;
					Some eelse
			in
			let phi = close_join_node ctx join e.epos in
			let e = {e with eexpr = TIf(econd,eif,eelse)} in
			e,(build_phi phi e.epos)
		and handle_loop_body ctx e =
			let join_top = mk_join_node() in
			let join_bottom = mk_join_node() in
			let unset = set_loop_join ctx join_top join_bottom in
			let close = branch ctx in
			let ebody = loop ctx e in
			close join_top;
			unset();
			add_vars join_top ctx.cur_vars;
			let phi_top = close_join_node ctx join_top e.epos in
			let phi_top_inv = invert_phi phi_top in
			let ebody = replace_locals phi_top_inv ebody in
			join_bottom.branches <- List.map (replace_vars phi_top_inv) join_bottom.branches;
			ctx.var_values <- PMap.map (fun e -> replace_locals phi_top_inv e) ctx.var_values;
			let phi_bottom = close_join_node ctx join_bottom e.epos in
			ebody,phi_bottom,phi_top
		and loop ctx e = match e.eexpr with
			(* var declarations *)
			| TVar(v,eo) ->
				declare_var ctx v;
				let eo = match eo with
					| None -> None
					| Some e ->
						let e = loop ctx e in
						ctx.var_values <- PMap.add v.v_id e ctx.var_values;
						Some e
				in
				{e with eexpr = TVar(v,eo)}
			| TFunction tf ->
				List.iter (fun (v,_) -> declare_var ctx v) tf.tf_args;
				let e' = loop ctx tf.tf_expr in
				{e with eexpr = TFunction {tf with tf_expr = e'}}
			(* var modifications *)
			| TBinop(OpAssign,({eexpr = TLocal v} as e1),e2) when v.v_name <> "this" ->
				let e2 = loop ctx e2 in
				let v = assign_var ctx v e2 e1.epos in
				{e with eexpr = TBinop(OpAssign,{e1 with eexpr = TLocal v},e2)}
			| TBinop(OpAssignOp op,({eexpr = TLocal v} as e1),e2) ->
				let e_op = mk (TBinop(op,e1,e2)) e.etype e.epos in
				ignore(assign_var ctx v e_op e1.epos);
				let e2 = loop ctx e2 in
				{e with eexpr = TBinop(OpAssignOp op,e1,e2)}
			| TUnop((Increment | Decrement as op),flag,({eexpr = TLocal v} as e1)) ->
				let op = match op with Increment -> OpAdd | Decrement -> OpSub | _ -> assert false in
				let e_one = mk (TConst (TInt (Int32.of_int 1))) com.basic.tint e.epos in
				let e_op = mk (TBinop(op,e1,e_one)) e.etype e.epos in
				ignore(assign_var ctx v e_op e1.epos);
				e
			(* var user *)
			| TLocal v ->
				let v = get_var ctx v e.epos in
				{e with eexpr = TLocal v}
			(* control flow *)
			| TIf(econd,eif,eelse) ->
				(* com.warning "If outside block" e.epos; *)
				let e,phi = handle_if ctx e econd eif eelse in
				mk (TBlock (e :: phi)) e.etype e.epos
			| TSwitch(e1,cases,edef) ->
				let e1 = loop ctx e1 in
				let join = mk_join_node() in
				let cases = List.map (fun (el,e) ->
					let close = branch ctx in
					let el = List.map (loop ctx) el in
					let e = loop ctx e in
					close join;
					el,e
				) cases in
				let edef = match edef with
					| Some e ->
						let close = branch ctx in
						let e = loop ctx e in
						close join;
						Some e
					| None ->
						begin match e1.eexpr with
							| TMeta((Meta.Exhaustive,_,_),_)
							| TParenthesis({eexpr = TMeta((Meta.Exhaustive,_,_),_)}) ->
								()
							| _ ->
								add_vars join ctx.cur_vars;
						end;
						None
				in
				let phi = close_join_node ctx join e.epos in
				let e = {e with eexpr = TSwitch(e1,cases,edef)} in
				append_phi e phi
			| TWhile(econd,ebody,mode) ->
				let econd = loop ctx econd in
				let ebody,phi_bottom,phi_top = handle_loop_body ctx ebody in
				let e_phi_top = to_block (build_phi phi_top e.epos) e.etype e.epos in
				let e = {e with eexpr = TWhile(econd,concat e_phi_top ebody,mode)} in
				append_phi e phi_bottom
			| TFor(v,e1,ebody) ->
				declare_var  ctx v;
				let e1 = loop ctx e1 in
				let ebody,phi_bottom,phi_top = handle_loop_body ctx ebody in
				let e_phi_top = to_block (build_phi phi_top e.epos) e.etype e.epos in
				let e = {e with eexpr = TFor(v,e1,concat e_phi_top ebody)} in
				append_phi e phi_bottom
			| TTry(e1,catches) ->
				let join_ex = mk_join_node() in
				let join_bottom = mk_join_node() in
				let unset = set_exception_join ctx join_ex in
				let e1 = loop ctx e1 in
				unset();
				add_vars join_bottom ctx.cur_vars;
				let phi = close_join_node ctx join_ex e.epos in
				let e_phi = to_block (build_phi phi e.epos) e.etype e.epos in
				let catches = List.map (fun (v,e) ->
					declare_var ctx v;
					let close = branch ctx in
					let e = loop ctx e in
					close join_bottom;
					let e = concat e_phi e in
					v,e
				) catches in
				let phi = close_join_node ctx join_bottom e.epos in
				let e = {e with eexpr = TTry(e1,catches)} in
				append_phi e phi
			| TBreak ->
				begin match ctx.loop_stack with
					| [] -> error "Break outside loop" e.epos
					| (_,join) :: _ -> add_vars join ctx.cur_vars
				end;
				e
			| TContinue ->
				begin match ctx.loop_stack with
					| [] -> error "Continue outside loop" e.epos
					| (join,_) :: _ -> add_vars join ctx.cur_vars
				end;
				e
			(* misc *)
			| TBlock el ->
				let rec loop2 el = match el with
					| e :: el ->
						begin match e.eexpr with
							| TIf(econd,eif,eelse) | TParenthesis({eexpr = TIf(econd,eif,eelse)}) ->
								let e,phi = handle_if ctx e econd eif eelse in
								(e :: phi) @ loop2 el
							| TParenthesis (e1) ->
								loop2 (e1 :: el)
							| _ ->
								let e = loop ctx e in
								e :: (loop2 el)
						end
					| [] ->
						[]
				in
				let el = loop2 el in
				{e with eexpr = TBlock el}
			| _ ->
				begin match ctx.exception_stack with
					| join :: _ when can_throw e -> add_vars join ctx.cur_vars
					| _ -> ()
				end;
				Type.map_expr (loop ctx) e
		in
		let ctx = {
			com = com;
			cur_vars = PMap.empty;
			loop_stack = [];
			exception_stack = [];
			cleanup = [];
			var_values = PMap.empty;
		} in
		let e = loop ctx e in
		e,ctx

	let unapply com e =
		let vars = ref PMap.empty in
		let declare v =
			vars := PMap.add (string_of_int v.v_id) v !vars;
		in
		let rec loop e = match e.eexpr with
			| TVar(v,eo) ->
				let e1 = match eo with
					| None -> None
					| Some e -> Some (loop e)
				in
				declare v;
				{e with eexpr = TVar(v,e1)}
			| TFunction tf ->
				List.iter (fun (v,_) -> declare v) tf.tf_args;
				{e with eexpr = TFunction {tf with tf_expr = loop tf.tf_expr}}
			| TTry (e1,catches) ->
				let e1 = loop e1 in
				let catches = List.map (fun (v,e) ->
					declare v;
					v,loop e
				) catches in
				{e with eexpr = TTry(e1,catches)}
			| TFor(v,e1,e2) ->
				declare v;
				let e1 = loop e1 in
				let e2 = loop e2 in
				{e with eexpr = TFor(v,e1,e2)}
			| TLocal ({v_extra = Some([],Some {eexpr = TLocal v'})} as v) when Meta.has (Meta.Custom ":ssa") v.v_meta ->
				{e with eexpr = TLocal v'}
			| TBlock el ->
				let rec filter e = match e.eexpr with
					| TMeta((Meta.Custom ":ssa",_,_),_) ->
						false
					| _ ->
						true
				in
				let el = List.filter filter el in
				let el = List.map loop el in
				{e with eexpr = TBlock el}
			| _ ->
				Type.map_expr loop e
		in
		loop e
end

module ConstPropagation = struct
	open Ssa

	let expr_eq e1 e2 = match e1.eexpr,e2.eexpr with
		| TConst ct1, TConst ct2 ->
			ct1 = ct2
		| _ ->
			false

	let rec value e = match e.eexpr with
(* 		| TBinop(OpAssign,_,e2) ->
			value e2 *)
		| TBinop(op,e1,e2) ->
			let e1 = value e1 in
			let e2 = value e2 in
			let e = {e with eexpr = TBinop(op,e1,e2)} in
			let e' = Optimizer.optimize_binop e op e1 e2 in
			e'
		| TUnop(op,flag,e1) ->
			let e1 = value e1 in
			Optimizer.optimize_unop {e with eexpr = TUnop(op,flag,e1)} op flag e1
		| TCall ({eexpr = TLocal {v_name = "__ssa_phi__"}},el) ->
			let el = List.map value el in
			begin match el with
				| [] -> assert false
				| e1 :: el ->
					if List.for_all (fun e2 ->
						let b = expr_eq e1 e2 in
						(* if e1.epos.pfile = "src/Main.hx" then Printf.printf "Eq: %s %s %b\n" (s_expr e1) (s_expr e2) b; *)
						b
					) el then
						e1
					else
						raise Not_found
			end
		| TConst ct ->
			begin match ct with
				| TThis | TSuper -> raise Not_found
				| _ -> e
			end
		| TParenthesis e1 | TMeta(_,e1) ->
			value e1
		| _ ->
			raise Not_found

	let apply ssa e =
		let rec loop e = match e.eexpr with
			| TLocal v when (match follow v.v_type with TDynamic _ -> false | _ -> not v.v_capture && not (type_has_analyzer_option v.v_type "no_const_propagation")) ->
				begin try
					let e' = PMap.find v.v_id ssa.var_values in
					let e' = value e' in
					e'
				with Not_found ->
					e
				end
			| TCall(e1,el) ->
			let e1 = loop e1 in
			let check e t =
				if type_has_analyzer_option t "no_const_propagation" then e
				else loop e
			in
			let el = Codegen.UnificationCallback.check_call check el e1.etype in
			{e with eexpr = TCall(e1,el)}
			| TBinop(OpAssign,({eexpr = TLocal v} as e1),e2) ->
				let e2 = loop e2 in
				ssa.var_values <- PMap.add v.v_id e2 ssa.var_values;
				{e with eexpr = TBinop(OpAssign,e1,e2)}
			| TUnop((Increment | Decrement),_,_)
			| TBinop(OpAssignOp _,_,_) ->
				e
			| TVar(v,Some e1) ->
				let e1 = loop e1 in
				ssa.var_values <- PMap.add v.v_id e1 ssa.var_values;
				{e with eexpr = TVar(v,Some e1)}
			| _ ->
				Type.map_expr loop e
		in
		loop e
end

module LocalDce = struct
	let apply com e =
		let in_loop = ref false in
		let is_used v = !in_loop || Meta.has Meta.Used v.v_meta in
		let use v = v.v_meta <- (Meta.Used,[],Ast.null_pos) :: v.v_meta in
		let rec filter e = match e.eexpr with
			| TVar(v,eo) when not (is_used v) ->
				begin match eo with
					| None ->
						None
					| Some e when not (Optimizer.has_side_effect e) ->
						None
					| Some e ->
						filter e
				end
			| TVar _ ->
				Some e
			| TBinop(OpAssign,{eexpr = TLocal v},e2) | TMeta(_,{eexpr = TBinop(OpAssign,{eexpr = TLocal v},e2)}) when not (is_used v) ->
				filter e2
			| TLocal v when not (is_used v) ->
				None
			| _ ->
				if Optimizer.has_side_effect e then
					Some e
				else
					None
		in
		let rec loop e = match e.eexpr with
			| TBlock el ->
				let rec block el = match el with
					| e :: el ->
						let last = el = [] in
						let el = block el in
						let e = loop e in
						begin if last then match e.eexpr with
							| TBinop(OpAssign,{eexpr = TLocal v},e2) when not (is_used v) ->
								el
							| _ ->
								e :: el
						else match filter e with
							| None ->
								el
							| Some e ->
								e :: el
						end
					| [] ->
						[]
				in
				{e with eexpr = TBlock (block el)}
			| TLocal v ->
				use v;
				e
			| TBinop(OpAssign,({eexpr = TLocal v} as e1),e2) ->
				use v;
				let e2 = loop e2 in
				{e with eexpr = TBinop(OpAssign,e1,e2)}
			| TIf ({ eexpr = TConst (TBool t) },e1,e2) ->
				(if t then loop e1 else match e2 with None -> { e with eexpr = TBlock [] } | Some e -> loop e)
			| TWhile(e1,e2,mode) ->
				let e2 = handle_loop_body e2 in
				let e1 = loop e1 in
				{e with eexpr = TWhile(e1,e2,mode)}
			| TFor(v,e1,e2) ->
				let e2 = handle_loop_body e2 in
				let e1 = loop e1 in
				{e with eexpr = TFor(v,e1,e2)}
			| _ ->
				Type.map_expr loop e
		and handle_loop_body e =
			let old = !in_loop in
			in_loop := true;
			let e = loop e in
			in_loop := old;
			e
		in
		loop e
end

let run_ssa com e =
	let all_locals = ref PMap.empty in
	let rec loop e = match e.eexpr with
		| TVar(v,eo) ->
			all_locals := PMap.add v.v_name true !all_locals;
			begin match eo with None -> () | Some e -> loop e end
		| _ ->
			Type.iter loop e
	in
	loop e;
	let n = ref (-1) in
	let rec gen_local t =
		incr n;
		let name = "_" ^ (string_of_int !n) in
		if PMap.mem name !all_locals then
			gen_local t
		else
			alloc_var name t
	in
	let do_optimize = Common.defined com Define.StaticAnalyzer in
	let do_simplify = match com.platform with
		| Cpp | Flash8 | Python -> true
		| _ -> false
	in
	let with_timer s f =
		let timer = timer s in
		let r = f() in
		timer();
		r
	in
	try
		let e = if do_simplify || do_optimize then
			with_timer "analyzer-simplify-apply" (fun () -> Simplifier.apply com gen_local e)
		else
			e
		in
		let e = if do_optimize then
				let e,ssa = with_timer "analyzer-ssa-apply" (fun () -> Ssa.apply com e) in
				let e = with_timer "analyzer-const-propagation" (fun () -> ConstPropagation.apply ssa e) in
				let e = with_timer "analyzer-ssa-unapply" (fun () -> Ssa.unapply com e) in
				List.iter (fun f -> f()) ssa.Ssa.cleanup;
				(* let e = LocalDce.apply com e in *)
				e
		else
			e
		in
		let e = if not do_simplify then
			with_timer "analyzer-simplify-unapply" (fun () -> Simplifier.unapply e)
		else
			e
		in
		e
	with Exit ->
		e

let run_expression_filters com t =
	match t with
	| TClassDecl c when (has_analyzer_option c.cl_meta "ignore") ->
		()
	| TClassDecl c ->
		let process_field cf =
			match cf.cf_expr with
			| Some e when not (has_analyzer_option cf.cf_meta "ignore") && not (Meta.has Meta.Extern cf.cf_meta) (* TODO: use is_removable_field *) ->
				cf.cf_expr <- Some (run_ssa com e);
			| _ -> ()
		in
		List.iter process_field c.cl_ordered_fields;
		List.iter process_field c.cl_ordered_statics;
		(match c.cl_constructor with
		| None -> ()
		| Some f -> process_field f);
(* 		(match c.cl_init with
		| None -> ()
		| Some e ->
			c.cl_init <- Some (run_ssa com e)); *)
	| TEnumDecl _ -> ()
	| TTypeDecl _ -> ()
	| TAbstractDecl _ -> ()

let apply com =
	List.iter (run_expression_filters com) com.types
