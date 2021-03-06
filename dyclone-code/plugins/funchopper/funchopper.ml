
open Pretty
open Cil
open Feature
module E = Errormsg
module H = Hashtbl

(* It's strange I can't google "copy file" function for OCaml *)
let copyfilefromto src dst =
  let inputfile = open_in_bin src in
  let outputfile = open_out_bin dst in
  let rec copybyte ic oc = 
      output_byte oc (input_byte ic); copybyte ic oc
  in
    try
        copybyte inputfile outputfile
    with
    | End_of_file -> prerr_string ("End of file: " ^ (string_of_int (pos_out outputfile)) ^ " bytes copied into '" ^ dst ^ "'.\n");
                     close_in inputfile; close_out outputfile
    | Sys_error msg -> prerr_string ("Can't open file in \" copyfilefromto\" src=" ^ src ^ ", dst=" ^ dst ^ "\n");
        raise (Sys_error msg)
    | e -> raise e

let sysargv0 = Sys.argv.(0);;

(* For CIL: in order to record the current "level",
 * we need both preorder and postorder processing of the node,
 * so we'll try to add calls to user-defined post processing
 * into CIL's visitor engine (which only has pre processing calls):
     * I'll just do it for visitCilStmt only for our purpose for now.
 * Update: found that the CIL visitor engine supports post processing
 * via "ChangeDoChildrenPost" action. TODO for performance (in CIL):
     * doVisit and doVisitList could check whether node' is changed
     * before applying ChangeDoChildrenPost action. *)

(* Be careful with the representation of the statements generated by CIL: some
 * may be different when --domakeCFG is used:
     * list of instr may be separated into a list of statements (of Instr)
     * extra levels of blocks may be introduced, e.g., for If branches.
     * ???
     * But, the order of the visited nodes seems the SAME
 These known differences should NOT cause our code chopping alg. to generate different results,
 although code format may be different. *)

(* Since our definition of primary statements are different for CIL's "stmt"
 * type and OCaml doesn't have support for "typeof", we have to use the
 * following type wrapper and pattern matching to make code look generic (and
 * memory efficient): *)
type primaryStmt =
    | CILstmt of stmt ref
    | CILInstr of instr ref * int * stmt ref (* instr and its offset (starting from 0) in its containing stmt *)

(* TODO: feature or bug: the location for different instr may be the same. So,
 * when "infraplacement" is activated, we may get more code trunks, but some of
 * them are actually the same *)
let get_pstmtLoc s = match s with
    CILstmt cs -> get_stmtLoc !cs.skind
  | CILInstr (is, i, cs) -> get_instrLoc !is

let output2list = ref true;;
let needOutVars = ref false;;
let needInVars = ref false;;
let makeCompilable = ref false;;
let deckardVecGen = ref false;;
let funNameList = ref [];;

let dirtostoreroot = ref "";;
(* TODO: it may be better to mirror the original directory structure.
 * however, it may be non-trivial since all *.i files are in one directory *)
let getDirforStore fd = 
    if !dirtostoreroot = "" then
        fd.svar.vname ^ "/" (* Use a directory named as the function name to store the code trunks. *)
    else
        !dirtostoreroot ^ "/" ^ fd.svar.vname ^ "/"
;;
let getFileBasename fn =
  let slash = 
    try
      String.rindex fn '/' + 1
    with Not_found -> 0
  in
  if slash >= String.length fn then
    None
  else
    Some (String.sub fn slash (String.length fn - slash))
;;
let getHeaderFileName (f:file) =
  let fnonly =
    match getFileBasename f.fileName with
    | None -> "__dyc_invalidfilename"
    | Some fn -> fn
  in
  if !dirtostoreroot = "" then (
    fnonly ^ ".hd.c"
  ) else (
    !dirtostoreroot ^ "/" ^ fnonly ^ ".hd.c"
  )
;;
let headerFileName = ref "";;

let dumpPStmt oc s = match s with
    CILstmt cs -> dumpStmt Cil.defaultCilPrinter oc 3 !cs; output_string oc "\n"
  | CILInstr (is, i, cs) -> fprint oc 80 (d_instr () !is); output_string oc "\n"

let psl2sl psl =
  (* Since we will transform each instr into its containing stmt, the stmt may
   * appear more than once if more than one instrs in the stmt are in the "psl"
   * list. So, the following folding function removes instrs that are in a same
   * stmt but not the first appeared in "psl" *)
  let containedCS = Hashtbl.create 32 in
  let trans sl ps = 
    match ps with
    | CILstmt cs ->
        if !cs.sid<0 then 
          E.s (E.log "FunChopper: Are you sure --domakeCFG is performed1?");
        if not(Hashtbl.mem containedCS cs) then (
          Hashtbl.add containedCS cs None;
          sl @ [!cs]
        ) else (
          E.s (E.log "FunChopper: a same stmt appears more than once in the code trunk? %a\n" d_stmt !cs)
        )
    | CILInstr (is, i, cs) ->
        if !cs.sid<0 then 
          E.s (E.log "FunChopper: Are you sure --domakeCFG is performed2?");
        if not(Hashtbl.mem containedCS cs) then (
          Hashtbl.add containedCS cs None;
          sl @ [!cs]
        ) else
          sl
  in
  List.fold_left trans [] psl
(* not a good alternative:
  try
    let trans ps = match ps with
            CILstmt cs ->
                if !cs.sid<0 then 
                    raise (Failure "Are you sure --domakeCFG is performed?");
                !cs
        |   CILInstr (is, i, cs) ->
                if !cs.sid<0 then 
                    raise (Failure "Are you sure --domakeCFG is performed?");
                ( match !cs.skind with
                      Instr il -> (
                        (* ?? why causing Out_of_memory:  if (List.nth il i) <> !is then ( *)
                        try
                          List.nth il i
                        with e -> (
                          ignore(E.log "FunChopper: can't find the corresponding instr for a primaryStmt.\n");
                          dumpStmt Cil.defaultCilPrinter stderr 0 !cs; output_string stderr "\n";
                          E.s (E.log "FunChopper: Assumption violation: stmt does not contain instr: \n-->stmt: %a\n-->instr: %a\n" d_stmt !cs d_instr !is)
                        ) )
                    | _ -> E.s (E.log "FunChopper: Assumption violation: stmt contains no instr. %a\n" d_stmt !cs)
                );
                !cs (* This may include extra instrs in code trunks and thus introduce extra RDs; 
                        it may be better to transform each instr list into stmt list before applying --domakeCFG. *)
                    (* Update: the above option is not good since later
                     * transformation may add in new instr list (in general);
                     * Update: the extra instrs included may not a big problem
                     * itself, but we have to make sure each extra instr only be
                     * included at most once; otherwise, may cause compiling
                     * failure and change the semantic of the code. *)
    in
    List.map trans psl
  with e -> (ignore(E.log "FunChopper: failure on transforming primaryStmt to CIL stmt.\n"); raise e)
*)

type traversalLog = {
    mutable minStmtN : int;
    mutable stmtStride : int;
    mutable trunkCounter : int;
    mutable trunkTotal : int;
    mutable sctot : int; mutable sccur : int;
    mutable level : int;
    mutable s1 : primaryStmt option;
    mutable s2 : primaryStmt option ;
    mutable s1filename : string;
    mutable s1file : out_channel;
    mutable s1list : primaryStmt list;
    mutable filelimit : int; (* how many code trunks at most a directory can contain *)
    mutable filetot : int; (* how many trunks are generated totally *)
    mutable filecur : int; (* how many trunks are generated for a function *)
    debug : bool ref
};;

let choppingData = {
    minStmtN = 3;
    stmtStride = 1;
    trunkCounter = 0;
    trunkTotal = 0;
    sctot = 0; sccur = 0; level = 0;
    s1 = None; s2 = None; (* not used yet 09/01/2008 *)
    s1filename = "";
    s1file = stdout;
    s1list = [];
    filelimit = 2000; (* it seems the longest one from Linux kernel is ~1600 lines in serpent_setkey from serpent.i *)
    filetot = 0;  (* not really used yet *)
    filecur = 0;
    debug = ref false
};;

(* Opt 1: set s1 and s2 (chopping parameters) in two nested traversals, 
 * and do the chopping during the same traversal as setting s2 *)
(* Opt 2: set all s1 and s2 first in one traversal, 
 * and do the chopping at a second traversal. 
 * Need more memory for book keeping; 
 * not sure how more efficient it would be due to a lot of lookups...TODO *)
(* Q: What forms are better for outputting the code trunks?
 * Need to investigate CIL source code to find it out:
     * dumpStmt pretty_printer out_channel indent_size stmt *)

(* Implementing Opt 1 *)
class funChopperS1 fnode = object (self)
    (* traverse every "primary" stmt, and set s1 *)
  inherit nopCilVisitor
  val mutable curStride : int = choppingData.stmtStride - 1 
  val mutable curFun : fundec ref = fnode
  val dirforStore = getDirforStore !fnode
  initializer choppingData.sctot <- 0; choppingData.sccur <- 0; choppingData.level <- 0;
              choppingData.s1filename <- dirforStore; choppingData.s1file <- stdout;
              choppingData.s1list <- []; choppingData.trunkCounter <- 0

  method vstmt (s : stmt) : stmt visitAction =
    let plusLevel _ = choppingData.level <- choppingData.level + 1 in
    (* let minusLevel _ = choppingData.level <- choppingData.level - 1 in *)
    let postLevel s = choppingData.level <- choppingData.level - 1; s in
    let setS1S2 ps = choppingData.sctot <- choppingData.sctot + 1;
        choppingData.sccur <- 0;
        curStride <- curStride + 1;
        if curStride < choppingData.stmtStride then (
          if !(choppingData.debug) then
            ignore(E.log "FunChopper: in S1, skip stmt:\n");
            dumpPStmt stderr ps
        ) else (
          choppingData.s1 <- Some ps;
          choppingData.s1filename <- dirforStore ^ !curFun.svar.vname ^ "_" ^ (string_of_int (get_pstmtLoc ps).line) ^ "-" ^ (string_of_int (get_pstmtLoc ps).byte);
          if !(choppingData.debug) then (
            ignore(E.log "FunChopper: setting file for a new s1: %s\n" choppingData.s1filename);
            dumpPStmt stderr ps
          );
          (* Too bad for OCaml: it often doesn't know where is the end of a "try...with"
           * operator; so I have to use a lot of "(...)". *)
          (try
            choppingData.s1file <- open_out choppingData.s1filename
          with e -> (prerr_string "FunChopper: File Exception in setS1S2.\n"; raise e));
          if !output2list then
            choppingData.s1list <- [];
          (let s2vis = new funChopperS2 curFun in ignore(visitCilFunction s2vis !curFun));
          (try
            close_out choppingData.s1file;
           with e -> (prerr_string "FunChopper: File close error in setS1S2.\n"; raise e)
          );
          if !(choppingData.debug) then
            ignore(E.log "FunChopper: remove temp file: %s\n" choppingData.s1filename);
          Unix.unlink choppingData.s1filename;
          curStride <- 0
        )
    in
    match s.skind with
      If _ | Switch _ | Loop _ -> begin
        setS1S2 (CILstmt (ref s));
        plusLevel ();
        ChangeDoChildrenPost (s, postLevel)
      end
    | Instr il -> begin
        let pos = ref 0 in
        let fInstr i = setS1S2 (CILInstr (ref i, !pos, ref s)); pos:= !pos+1 in
        List.iter fInstr il; DoChildren
      end
    | Return _ (* it currently shouldn't occur because we change all "return" to "goto __dyc_dummy_label" *)
    | Goto _ | Break _ | Continue _ -> begin
        (* Opt 1: treat these "simple" stmts the same as an instr. Make
         * sure funChopperS2 is also set correspondingly for these cases 
        setS1S2 (CILstmt (ref s));
        DoChildren *)
        (* Opt 2: don't start a chopping at these stmts, and don't count them
         * into "sctot", and we don't output them. TODO: is this good? *)
        SkipChildren 
      end
    | Block b -> DoChildren (* not a stmt for our purpose *)
    | _ -> SkipChildren (* ignore TryFinally and TryExcept *)
end

and funChopperS2 fnode = object (self)
    (* traverse appropriate stmt to set s2 and output stmts
     * in between (make it inclusive). *)
  inherit nopCilVisitor
  val curFun : fundec ref = fnode
  val dirforStore = getDirforStore !fnode
  val mutable curStride = choppingData.stmtStride - 1
  val mutable s2level = 0
  val mutable sameParentLevel = true
  val mutable s2sctot = 0
  val mutable s1s2filename = ""

  (* TODO: if we want to output a scope even if it contains too few stmts,
   * e.g., a small function, we need to add a check on choppingData.sccur in postorder. *)
  method vstmt (s : stmt) : stmt visitAction =
    if not sameParentLevel then SkipChildren
    else begin
      (* N1: we are using "level" and "sctot" to locate a stmt 
       * so that we can compare the location of s1 and s2;
       * but we have to traverse the whole AST again. TODO: optimize it. *)
      let outputPStmt ps = 
        if !(choppingData.debug) then (
          ignore(E.log "FunChopper: handling s2sctot=%d, sctot=%d, s2level=%d, level=%d, sameParentLevel=%B, stmt-->"
                        s2sctot choppingData.sctot s2level choppingData.level sameParentLevel);
          dumpPStmt stderr ps
        );
        if (s2sctot>=choppingData.sctot) (* s2 occurs no earlier than s1 *) &&
           (s2level==choppingData.level) (* s2 is in the same level as s1 *) &&
            sameParentLevel then (
            (* Prob 1: "same level" is not enough; they may be from different
             * "parent" levels; Need to use a flag to make the level indicator
             * parent-sensitive. Done. *)
            (* Prob 2: a code trunk may across two branches of an If stmt;
             * it seems no good solution unless modifying the visitor engine.
             * The same prob for Switch cases. TODO. *)
            if !(choppingData.debug) then
              ignore(E.log "FunChopper: adding the stmt into s1file: %s\n" choppingData.s1filename);
            dumpPStmt choppingData.s1file ps;
            if !output2list then
              choppingData.s1list <- choppingData.s1list@[ps];
            if s2sctot-choppingData.sctot+1>=choppingData.minStmtN then (
              curStride <- curStride + 1;
              if curStride < choppingData.stmtStride then (
                if !(choppingData.debug) then
                  ignore(E.log "FunChopper: in S2, skip stmt:\n");
                dumpPStmt stderr ps
              ) else (
                choppingData.trunkCounter <- choppingData.trunkCounter + 1;
                choppingData.trunkTotal <- choppingData.trunkTotal + 1;

                (* This can not give unique file name; need to run a raw CIL
                 * first (in a separate script) and use "--commPrintLnSparse" so
                 * that every stmt has different line numbers. *)
                (* Update: a separate run of CIL is improving the running performance of our funchopper,
                 * but it is NOT enough to assign each stmt a unique line number because some CIL-generated
                 * stmts will use the same line number when "--domakeCFG" is called before funchopper, and 
                 * because we can not use "--domakeCFG" separately due to the CIL label bugs *)
                s1s2filename <- choppingData.s1filename ^ "_" ^ (string_of_int (get_pstmtLoc ps).line) ^ "-" ^ (string_of_int (get_pstmtLoc ps).byte);

                (* possible "infraplacement" before generating new files *)
                if choppingData.filelimit > 0 && choppingData.filecur >= choppingData.filelimit then (
                  if !(choppingData.debug) then
                    ignore(E.log "FunChopper: infraplacement is activating at No. %d before %s ...\n" choppingData.filetot s1s2filename);
                  (* first, close the s1file *)
                  (try
                    close_out choppingData.s1file;
                   with e -> (prerr_string "FunChopper: Error: File close error before infraplacement.\n"; raise e));
                  (* then, move it somewhere else since we don't want to infraplace it *)
                  (match Unix.system("mv " ^ choppingData.s1filename ^ " " ^ (Filename.dirname choppingData.s1filename) ^ "/..") with
                   | Unix.WEXITED 0 -> ()
                   | _ -> E.s (E.log "FunChopper: Error: prelude for infraplacement failed: mv %s ..\n" choppingData.s1filename)
                  );
                  (* then, infraplace *)
                  (match Unix.system( (Filename.dirname sysargv0) ^ "/../../../modules/tools/reinfraplace "
                                    ^ dirforStore ^ " DIRRTT " ^ (string_of_int choppingData.filelimit) ) with
                   | Unix.WEXITED 0 -> ()
                   | _ -> E.s (E.log "FunChopper: Error: infraplacement failure: %s DIRRTT %d\n" dirforStore choppingData.filelimit)
                  );
                  (* then, move the s1file back, and reopen it *)
                  (match Unix.system( "mv " ^ (Filename.dirname choppingData.s1filename) ^ "/../"
                                            ^ (Filename.basename choppingData.s1filename) ^ " " ^ choppingData.s1filename ) with
                   | Unix.WEXITED 0 -> ()
                   | _ -> ignore(E.log "FunChopper: Warning: finale for infraplacement failed: '%s' is missing.\n" choppingData.s1filename)
                  );
                  (try
                    choppingData.s1file <- open_out_gen [Open_wronly; Open_creat; Open_append; Open_text] 0o666 choppingData.s1filename
                   with e -> (prerr_string "FunChopper: File exception in outputPStmt.\n"; raise e)
                  );
                  (* finally, reset the counter controlling infraplacement *)
                  choppingData.filecur <- 0
                );
                if !(choppingData.debug) then (
                    ignore(E.log "FunChopper: setting file for a new s2: %s\n" s1s2filename);
                    (* save a copy of the current output file: *)
                    (try
                        close_out choppingData.s1file;
                     with e -> (prerr_string "FunChopper: File close error in outputPStmt.\n"; raise e)
                    );
                    ignore(E.log "FunChopper: output a new code trunk into %s\n" s1s2filename);
                    (* only make the intermediate copy during debugging: *)
                    copyfilefromto choppingData.s1filename s1s2filename
                );
                choppingData.filecur <- choppingData.filecur + 1; (* used for "infraplacement" *)
                choppingData.filetot <- choppingData.filetot + 1;
                if !(choppingData.debug) then (
                  try
                      choppingData.s1file <- open_out_gen [Open_wronly; Open_creat; Open_append; Open_text] 0o666 choppingData.s1filename
                  with e -> (prerr_string "FunChopper: File exception in outputPStmt.\n"; raise e)
                );
                if !output2list then (
                    let slist = psl2sl choppingData.s1list in
                    (* May put here whatever we need to do for the stmt list *)
                    if !needOutVars then (
                        if !(choppingData.debug) then
                            ignore(E.log "FunChopper: computing RDs for the code trunk: %s.rds\n" s1s2filename);
                        let rdsfile =
                            (* ignore(E.log "FunChopper: opening RD file: %s.rds\n" s1s2filename); *)
                            open_out (s1s2filename ^ ".rds")
                        in
                        ignore(LocalRDs.outputLocalRDs ~oc:rdsfile slist);
                        close_out rdsfile
                    );
                    if !needInVars then (
                      if !(choppingData.debug) then
                        ignore(E.log "FunChopper: computing Liveness for the code trunk: %s.ins\n" s1s2filename);
                      let insfile =
                        (* ignore(E.log "FunChopper: opening RD file: %s.rds\n" s1s2filename); *)
                        open_out (s1s2filename ^ ".ins")
                      in
                      ignore(LocalLiveness.outputLocalLiveness ~oc:insfile slist);
                      close_out insfile
                    );
                    if !makeCompilable then (
                      if !(choppingData.debug) then
                        ignore(E.log "FunChopper: try to make compilable code trunk: %s.c\n" s1s2filename);
                      let includehd = (* we always put .hd.c.h file one level above if "infraplacement" is not enabled.*)
                        (* It may be better to use absolute path when
                         * "infraplacement" is enabled, so that we could easily
                         * infraplace code trunks. However, we would need "sed -i ..." (hopefully it would be rare)
                         * when we move around the .hd.c/h files.
                         * Update: an alternative, we could ask the scripts for
                         * compilation to search for/link the headers more "intelligently".
                         * With the update, we don't have to use abs path for the include: 
                        if (!headerFileName.[0] == '/') then ( (* absolute path *)
                          "#include \"" ^ !headerFileName ^ ".h\""
                        ) else *) (
                          match getFileBasename !headerFileName with
                          | None -> "#include \"__dyc_invalidfilename.hd.c.h\"" (* should cause compilation failure *)
                          | Some fn -> ( "#include \"../" ^ fn ^ ".h\"" )
                        )
                      in
                      let cfile = open_out (s1s2filename ^ ".foo.c") in
                      Printf.fprintf cfile "%s\n" "#include <dycfoo.h>";
                      Printf.fprintf cfile "%s\n" includehd;
                      let wrapper, randomGen, invars, rds = Trunkwrapper.trunkwrapper !curFun slist in
                      ignore(Trunkwrapper.dumpTrunkWrapper ~oc:cfile wrapper);
                      close_out cfile;
                      Trunkwrapper.restoreStmtSkinds Trunkwrapper.changedStmtSkind;
                      let rvfile = open_out (s1s2filename ^ ".gen.c") in
                      Printf.fprintf rvfile "%s\n" "#include <dycfoo.h>";
                      Printf.fprintf rvfile "%s\n" includehd;
                      ignore(Trunkwrapper.dumpTrunkWrapper ~oc:rvfile randomGen);
                      close_out rvfile;
                      let insfile = open_out (s1s2filename ^ ".foo.ins") in
                      ignore(LocalLiveness.dumpLocalLiveness ~oc:insfile invars);
                      close_out insfile;
                      let rdsfile = open_out (s1s2filename ^ ".foo.rds") in
                      ignore(LocalRDs.dumpLocalRDs ~oc:rdsfile rds);
                      close_out rdsfile
                    );
                    if !deckardVecGen then (
                      if !(choppingData.debug) then
                        ignore(E.log "FunChopper: try to generate a deckard vector for the code trunk: %s.vec\n" s1s2filename);
                      let vec = Array.make Stmtvecgen.deckardDimension 0 in
                      let veccounter v s = 
                        let vg = new Stmtvecgen.nodeVisitor v in
                        ignore(visitCilStmt vg s);
                        v
                      in
                      let v = List.fold_left veccounter vec slist in
                      let vecfile = open_out (s1s2filename ^ ".foo.vec") in
                      fprintf vecfile "# FILE:%s.foo.c, LINE:%d, OFFSET:%d, NODE_KIND:0, CONTEXT_INFO:<none>, CONTEXT_KIND:0, NEIGHBOR_KIND:0, NUM_NODE:%d, NUM_DECL:0, NUM_STMT:0, NUM_EXPR:0, TBID:%d, TEID:%d, VARs:{}0,\n"
                              s1s2filename
                              (match choppingData.s1 with None -> 0 | Some ps1 -> (get_pstmtLoc ps1).line)
                              (get_pstmtLoc ps).line (Stmtvecgen.vecSize v)
                              (match choppingData.s1 with None -> 0 | Some ps1 -> (get_pstmtLoc ps1).byte)
                              (get_pstmtLoc ps).byte;
                      Stmtvecgen.outputVec ~oc:vecfile v;
                      close_out vecfile
                    )
                )
              );
              curStride <- 0
            )
        )
      in
      let countOutputPStmt ps = s2sctot <- s2sctot + 1;
            outputPStmt ps in
      let countEmptyPStmt ps = 
        if !(choppingData.debug) then
          ignore(E.log "FunChopper: handling an empty stmt when s2sctot=%d, sctot=%d, s2level=%d, level=%d, sameParentLevel=%B\n"
                        s2sctot choppingData.sctot s2level choppingData.level sameParentLevel);
        (* check the same condition as outputPStmt *)
        if (s2sctot>=choppingData.sctot) (* s2 occurs no earlier than s1 *) &&
           (s2level==choppingData.level) (* s2 is in the same level as s1 *) &&
            sameParentLevel then (
            if !output2list then
              if !(choppingData.debug) then
                ignore(E.log "FunChopper: adding the empty stmt into choppingData.s1list\n");
              choppingData.s1list <- choppingData.s1list@[ps];
              (* TODO: better to dump this "empty" stmt since it may have labels;
               * but it is seemly not useful for our "--compilable" option *)
        )
      in
      let plusLevel _ = s2level <- s2level + 1 in
      let minusLevel _ = s2level <- s2level - 1 in
      let validateLevel _ = 
        if sameParentLevel &&
            s2sctot>choppingData.sctot &&
            s2level<choppingData.level then 
                sameParentLevel <- false in
      let postLevel s = minusLevel (); validateLevel (); s in (* For preorder style chopping *)
      let postLevelChop s = minusLevel (); validateLevel (); outputPStmt (CILstmt (ref s)); s in (* For postorder style chopping *)
      (* counting s2sctot and s2level for locating s2: *)
      match s.skind with
        If _ | Switch _ | Loop _ -> begin
        (* Opt 1: Preorder-style chopping: 
          countOutputPStmt (CILstmt (ref s));
          plusLevel ();
          ChangeDoChildrenPost (s, postLevel) *)
        (* Opt 2: Postorder-style chpping: in order to count all substmts into 
         * "s2sctot" when such stmts are the last in the code trunk (the style
         * does not matter for other stmts): *)
          s2sctot <- s2sctot + 1;
          plusLevel ();
          ChangeDoChildrenPost (s, postLevelChop)
        end
      | Instr il -> begin
          match il with
          | [] -> (
              (* Even if the stmt is empty, add it into the s1list to maintain
               * the CIL's CFG; but don't increase s2sctot *)
              countEmptyPStmt (CILstmt (ref s));
              SkipChildren
            )
          | _ -> (
              let pos = ref 0 in
              let fInstr i = countOutputPStmt (CILInstr (ref i, !pos, ref s)); pos:=!pos+1 in
              List.iter fInstr il;
              DoChildren
            )
        end
      | Return _ (* it currently shouldn't occur because we change all "return" to "goto __dyc_dummy_label" *)
      | Goto _ | Break _ | Continue _ -> begin
          (* Opt 1: treat these "simple" stmts the same as an instr. Make
           * sure funChopperS1 is also set correspondingly for these cases 
          countOutputPStmt (CILstmt (ref s));
          DoChildren *)
          (* Opt 2: we can end a chopping at these stmts, but don't count them
           * into "s2sctot"; but we have to output them. *)
          outputPStmt (CILstmt (ref s));
          SkipChildren 
        end
      | Block b -> DoChildren (* not a stmt for our purpose *)
      | _ -> SkipChildren (* ignore TryFinally and TryExcept *)
    end
end

class fileChopperVisitor = object (self)
  inherit nopCilVisitor

  (* for each function, apply the chopper *)
  (* Update: add support for "infraplacement". If enabled, we should probably use
   * absolute paths for header file names; this means we have to "sed -i ..." 
   * if we move those generated files.
   * Update: still use relative path for "#include ...", but change the
   * compilation scripts to search for the headers in parent directories. *)
  method vfunc (f : fundec) : fundec visitAction =
      if !(choppingData.debug) then
        ignore(E.log "FunChopper: start a new fun: %s (%s)\n" f.svar.vname f.svar.vdecl.file);
      if List.length !funNameList > 0 && not(List.mem f.svar.vname !funNameList) then (
        if !(choppingData.debug) then
          ignore(E.log "FunChopper: skipping the fun: %s\n" f.svar.vname);
        SkipChildren
      ) else (
        (* replace fun calls with a new in-var *)
        let replaceFunCall = new Trunkwrapper.funReplaceVisitorClass f Trunkwrapper.funcallVars in
        ignore(visitCilFunction replaceFunCall f); (* in-place change fun calls *)
        (* Create a subdirectory for each function and store all code trunk files
         * in the subdirectory: *)
        (try
          Unix.mkdir (getDirforStore f) 0o777;
          choppingData.filecur <- 0; (* used for "infraplacement" *)
          let afVis = new funChopperS1 (ref f) in
          ignore(visitCilFunction afVis f);
          (* TODO: ouput the function even if it is "too small"
          if choppingData.trunkCounter <= 0 then (
            to copy code from outputPStmt and do variaous things consistently;
            or, restructure/optimize the code in funChopperS1/S2 to do it --> may not be easy
            since it's not easy to know in S2 when we reach the last stmt in a function body.
          ) *)
        with Unix.Unix_error(ecode, fn, param) ->
          prerr_string ("Unix error (continue next chopping): " ^ (Unix.error_message ecode) ^ 
          "\n\tFunction: " ^ fn ^ "(" ^ param ^ ")\n")
        );
        SkipChildren
      )

end

let funChopperEntry (f:file) =
  if !(choppingData.debug) then
    ignore(E.log "FunChopper: start a new file: %s\n" f.fileName);

  headerFileName := getHeaderFileName f;
  (* separate type signatures from function definitions in favor of
   * incremental compilation *)
  if !(choppingData.debug) then
    ignore(E.log "FunChopper: generating a header .hd.c.h file: %s\n" (!headerFileName ^ ".h"));
  let gfileh = open_out (!headerFileName ^ ".h") in
  let typeGen = new Trunkwrapper.typeGenVisitorClass ~oc:gfileh () in
  visitCilFileSameGlobals typeGen f;
  Trunkwrapper.dumpTypeFunMapHeaders ~oc:gfileh Trunkwrapper.typeFunMap;
  close_out gfileh;
  if !(choppingData.debug) then
    ignore(E.log "FunChopper: generating a .hd.c file: %s\n" !headerFileName);
  let gfile = open_out !headerFileName in
  let hfn =
    match getFileBasename !headerFileName with
    | None -> "__dyc_invalidfilename.hd.c" (* should cause compilation failure *)
    | Some fn -> fn
  in
  Printf.fprintf gfile "%s\n" ("#include \"" ^ hfn ^ ".h\"");
  Trunkwrapper.dumpTypeFunMapDefs ~oc:gfile Trunkwrapper.typeFunMap;
  close_out gfile;
  if !(choppingData.debug) then
    ignore(E.log "FunChopper: totally %d global types are collected\n" !Trunkwrapper.globalTypeCount);
  let aaVisitor = new fileChopperVisitor in
  visitCilFileSameGlobals aaVisitor f

let feature : Feature.t = 
  { fd_name = "funchopper";
    fd_enabled = false;
    fd_description = "Chop a function body into chunks of code.";
    (* The following options require --domakeCFG *)
    fd_extraopt = [ ("--local-RDs", Arg.Unit (fun _ -> needOutVars := true),
                     " infer reaching definitions for the end of each code trunk");
                    ("--local-liveness", Arg.Unit (fun _ -> needInVars := true),
                     " infer live variables for the beginning of each code trunk");
                    ("--store-directory", Arg.String (fun s -> if ( (String.get s 0)='-' ) then dirtostoreroot := (String.sub s 2 (String.length s - 2)) else dirtostoreroot := s),
                     "=<dir> the directory for storing results. Must exist.");
                    ("--min-stmt-number", Arg.Int (fun s -> if s>0 then choppingData.minStmtN <- s else E.s(E.log "FunChopper: --min-stmt-number must >=1\n")),
                     ("=<number> the minimum number of stmts for chopping. Must >=1. Default " ^ (string_of_int choppingData.minStmtN)));
                    (* two locations may be controled by "stride":
                      * when moving the end of a sliding window forward;
                      * when moving the beginning of a sliding window forward
                      *)
                    ("--stmt-stride", Arg.Int (fun s -> if s>0 then choppingData.stmtStride <- s else E.s(E.log "FunChopper: --stmt-stride must >=1\n")),
                     ("=<number> the stride for the next code chopping. Must >=1. Default " ^ (string_of_int choppingData.stmtStride)));
                    ("--compilable", Arg.Unit (fun _ -> makeCompilable := true),
                     " whether to wrap the code trunk in a compilable unit");
                    ("--fun-name-list", Arg.String (fun s -> funNameList := Str.split (Str.regexp "[ \t]+") s),
                     "=\"fun-names-separated-by-blanks\" the white-list of functions that will be chopped. Empty means all.");
                    ("--infraplacement-limit", Arg.Int (fun s -> choppingData.filelimit <- s),
                     ("=<number> the max number of code trunks a directory can contain. Default " ^(string_of_int choppingData.filelimit)^ ". Disabled when <=0."));
                    ("--deckard-vector", Arg.Unit (fun _ -> deckardVecGen := true),
                     " whether to generate a deckard vector for the code trunk")
                ];
    fd_doit = funChopperEntry;
    fd_post_check = false;
  } 

let () = Feature.register feature
(* TODO:
  * Added "stride" parameter, but need to generate the last stride even if it is
  * smaller than the specified "stride" --> may not be easy since it's
  * inconvenient to know which is the "last" stmt in a function body or a
  * compound stmt. Current implementation "stride==1" has no such need.
  *
  * Treat undefined/unsupported struct/union fields;
    *)
