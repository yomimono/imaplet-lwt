(*
 * Copyright (c) 2013-2014 Gregory Tsipenyuk <gregtsip@cam.ac.uk>
 * 
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open Lwt
open Core.Std
open BatLog
open Imaplet_types
open Response
open Regex
open Context
open Utils

exception SystemError of string
exception ExpectedDone

let response context state resp mailbox =
  begin
  match state with
  |None -> ()
  |Some state -> context.state := state
  end;
  begin
  match mailbox with
  |None -> ()
  |Some mailbox -> context.mailbox := mailbox
  end;
  return resp

(* handle all commands
 * return either Ok, Bad, No, Preauth, Bye, or Continue response
 *)

(*
 * Any state
 *)
let handle_id context l =
  write_resp context.!netw (Resp_Untagged (formated_id(Configuration.id))) >>
  response context None (Resp_Ok (None, "ID completed")) None

let handle_capability context = 
  begin
  if (Amailbox.user context.!mailbox) = None then
    write_resp context.!netw (Resp_Untagged (formated_capability(Configuration.capability)))
  else
    write_resp context.!netw (Resp_Untagged (formated_capability(Configuration.auth_capability)))
  end >>
  response context None (Resp_Ok (None, "CAPABILITY completed")) None

let handle_logout context =
  write_resp context.!netw (Resp_Bye(None,"")) >>
  response context (Some State_Logout) (Resp_Ok (None, "LOGOUT completed")) None

(** TBD should have a hook into the maintenance to recet inactivity **)
let handle_noop context =
  response context None (Resp_Ok (None, "NOOP completed")) None

let handle_idle context =
  begin
  match Amailbox.user context.!mailbox with
  | Some user -> 
    Easy.logf `debug "handle_idle ======== %s %s\n%!" (Int64.to_string context.id) user;
    Connections.add_id context.id user context.!netw 
  | None -> ()
  end;
  response context None (Resp_Any ("+ idling")) None

let handle_done context =
  Connections.rem_id context.id;
  response context None (Resp_Ok (None, "IDLE")) None

(**
 * Not Authenticated state
**)
let handle_authenticate context auth_type text =
  Account.authenticate auth_type text >>= function
    | Ok (m,u) -> response context (Some State_Authenticated) m (Some (Amailbox.create u))
    | Error e -> response context None e None

let handle_login context user password =
  Account.login user password >>= function
    | Ok (m,u) -> response context (Some State_Authenticated) m (Some (Amailbox.create u))
    | Error e -> response context None e None

let handle_starttls context =
 let open Server_config in
 if srv_config.!starttls = true then (
   context.Context.starttls () >>= fun (r,w) ->
   context.netr := r;
   context.netw := w;
   response context None (Resp_Ok(None,"STARTTLS")) None
 ) else
   response context None (Resp_Bad(None,"")) None
(**
 * Done Not Authenticated state
**)

(**
 * Authenticated state
**)

let quote_file file =
  if match_regex file "[ ]" then
    "\"" ^ file ^ "\""
  else
    file

let list_resp flags file =
  let flags_str = String.concat ~sep:" " flags in
  let l = List.concat [["LIST ("]; [flags_str]; [") \"/\" "]; [quote_file file]] in 
  Resp_Untagged(String.concat ~sep:"" l)

let handle_list context reference mailbox lsub =
  begin
  if lsub = false then
    Amailbox.listmbx context.!mailbox reference mailbox
  else
    Amailbox.lsubmbx context.!mailbox reference mailbox
  end >>= fun l ->
  Lwt_list.iter_s (fun (file, flags) ->
      write_resp context.!netw (list_resp flags file)
  ) l >>
  response context None (Resp_Ok(None, "LIST completed")) None

(** review - where the flags are coming from TBD **)
let handle_select context mailbox rw =
  (if rw then
    Amailbox.select context.!mailbox mailbox
  else
    Amailbox.examine context.!mailbox mailbox
  ) >>= function
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist:" ^ mailbox)) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable :" ^ mailbox)) None
  | `Error e -> response context None (Resp_No(None, e)) None
  | `Ok (mbx, header) ->
    let open Storage_meta in
    if header.uidvalidity = "" then (** give up TBD **)
      response context None (Resp_No(None,"Uidvalidity failed")) None
    else
    (
      let (flags,prmnt_flags) = Configuration.get_mbox_flags in
      let flags = to_plist (String.concat ~sep:" " flags) in
      let pflags = to_plist (String.concat ~sep:" " prmnt_flags) in
      write_resp context.!netw (Resp_Untagged ("FLAGS " ^ flags)) >>
      write_resp context.!netw (Resp_Ok (Some RespCode_Permanentflags, pflags)) >>
      write_resp context.!netw (Resp_Untagged ((string_of_int header.count) ^ " EXISTS")) >>
      write_resp context.!netw (Resp_Untagged ((string_of_int header.recent) ^ " RECENT")) >>
      write_resp context.!netw (Resp_Ok (Some RespCode_Uidvalidity, header.uidvalidity)) >>
      write_resp context.!netw (Resp_Ok (Some RespCode_Uidnext, string_of_int header.uidnext)) >>
      begin
      if rw then
        response context (Some State_Selected) (Resp_Ok(Some RespCode_Read_write, "")) (Some mbx)
      else
        response context (Some State_Selected) (Resp_Ok(Some RespCode_Read_only, "")) (Some mbx)
      end
    )

(** create a mailbox **)
let handle_create context mailbox =
  Amailbox.create_mailbox context.!mailbox mailbox >>= function
    | `Ok -> response context None (Resp_Ok(None, "CREATE completed")) None
    | `Error e -> response context None (Resp_No(None,e)) None

(** delete a mailbox **)
let handle_delete context mailbox =
  Amailbox.delete_mailbox context.!mailbox mailbox >>= function
    | `Ok -> response context None (Resp_Ok(None, "DELETE completed")) None
    | `Error e -> response context None (Resp_No(None,e)) None

(** rename a mailbox **)
let handle_rename context src dest = 
  Amailbox.rename_mailbox context.!mailbox src dest >>= function
    | `Ok -> response context None (Resp_Ok(None, "RENAME completed")) None
    | `Error e -> response context None (Resp_No(None,e)) None

(** subscribe a mailbox **)
let handle_subscribe context mailbox = 
  Amailbox.subscribe context.!mailbox mailbox >>= function
    | `Ok -> response context None (Resp_Ok(None, "SUBSCRIBE completed")) None
    | `Error e -> response context None (Resp_No(None,e)) None

(** subscribe a mailbox **)
let handle_unsubscribe context mailbox = 
  Amailbox.unsubscribe context.!mailbox mailbox >>= function
    | `Ok -> response context None (Resp_Ok(None, "UNSUBSCRIBE completed")) None
    | `Error e -> response context None (Resp_No(None,e)) None

let handle_status context mailbox optlist =
  let open Storage_meta in
  Amailbox.examine context.!mailbox mailbox >>= function
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist:" ^ mailbox)) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable :" ^ mailbox)) None
  | `Error e -> response context None (Resp_No(None, e)) None
  | `Ok (mbx, header) ->
  if header.uidvalidity = "" then (** give up TBD **)
  (
    response context None (Resp_No(None,"Uidvalidity failed")) None
  )
  else
  (
    let output = (List.fold optlist ~init:"" ~f:(fun acc opt ->
      let str = (match opt with
      | Stat_Messages -> "EXISTS " ^ (string_of_int header.count)
      | Stat_Recent -> "RECENT " ^ (string_of_int header.recent)
      | Stat_Uidnext -> "UIDNEXT " ^(string_of_int header.uidnext)
      | Stat_Uidvalidity -> "UIDVALIDITY " ^ header.uidvalidity
      | Stat_Unseen -> "UNSEEN " ^ (string_of_int header.nunseen)
      ) in 
      if acc = "" then
        acc ^ str
      else
        acc ^ " " ^ str
    )) in
    write_resp context.!netw (Resp_Untagged (to_plist output)) >>
    response context None (Resp_Ok(None, "STATUS completed")) None
  )

(* send unsolicited response to idle clients *)
let idle_clients context =
  let open Storage_meta in
  let get_status () =
   match Amailbox.selected_mbox context.!mailbox with
   | Some mailbox ->
    (Amailbox.examine context.!mailbox mailbox >>= function
    |`Ok(mbx,header) -> return (Some header)
    | _ -> return None
    )
   | None -> return None
  in
  match Amailbox.user context.!mailbox with
  |Some user ->
    let idle = List.fold context.!connections ~init:[] ~f:(fun acc i ->
      let (_,u,_) = i in
      if u = user then 
        i :: acc
      else
        acc
    ) in
    if List.length idle > 0 then (
      get_status () >>= function
      | Some status ->
        Lwt_list.iter_s (fun i ->
          let (id,u,w) = i in
          if u = user then (
            Easy.logf `debug "=========== idle_clients %s %s\n%!" (Int64.to_string id) u;
            write_resp_untagged w ("EXISTS " ^ (string_of_int status.count)) >>
            write_resp_untagged w ("RECENT " ^ (string_of_int status.recent))
          ) else (
            return()
          )
        ) idle
      | None -> return ()
    ) else (
      return ()
    )
  |None -> return ()

(** handle append **)
let handle_append context mailbox flags date literal =
  Easy.logf `debug "handle_append\n%!";
  (** is the size sane? **)
  let size = (match literal with
  | Literal n -> n
  | LiteralPlus n -> n) in
  let open Server_config in
  if size > srv_config.max_msg_size then
    response context None (Resp_No(None,"Max message size")) None
  else (
    Amailbox.append context.!mailbox mailbox context.!netr context.!netw flags date literal >>= function
      | `NotExists -> response context None (Resp_No(Some RespCode_Trycreate,"")) None
      | `NotSelectable -> response context None (Resp_No(Some RespCode_Trycreate,"Noselect")) None
      | `Error e -> response context None (Resp_No(None,e)) None
      | `Eof i -> response context (Some State_Logout) (Resp_No(None, "Truncated Message")) None
      | `Ok -> 
        idle_clients context >>= fun () ->
        response context None (Resp_Ok(None, "APPEND completed")) None
  )

(**
 * Done Authenticated state
**)

(**
 * Selected state
**)

let handle_close context =
  let mbx = Amailbox.close context.!mailbox in
  response context (Some State_Authenticated) (Resp_Ok(None, "CLOSE completed")) (Some mbx)

let rec print_search_tree t indent =
  Easy.logf `debug "search ------\n%!";
  let indent = indent ^ " " in
  let open Amailbox in
  match t with
  | Key k -> Easy.logf `debug "%s-key\n%!" indent
  | KeyList k -> Easy.logf `debug "%s-key list %d\n%!" indent (List.length k);
    List.iter k ~f:(fun i -> print_search_tree i indent)
  | NotKey k -> Easy.logf `debug "%s-key not\n%!" indent; print_search_tree k indent
  | OrKey (k1,k2) -> Easy.logf `debug "%s-key or\n%!" indent; print_search_tree k1 indent; print_search_tree k2 indent

(** handle the charset TBD **)
let handle_search context charset search buid =
  Amailbox.search context.!mailbox search buid >>= function 
    (** what do these two states mean in this contex? TBD **)
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist")) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable")) None
  | `Error e -> response context None (Resp_No(None,e)) None
  | `Ok r -> 
    write_resp context.!netw (Resp_Untagged (List.fold r ~init:""  ~f:(fun acc i ->
      let s = string_of_int i in
      if acc = "" then 
        s 
      else 
        s ^ " " ^ acc)
    )) >>
    response context None (Resp_Ok(None, "SEARCH completed")) None

let handle_fetch context sequence fetchattr buid =
  Easy.logf `debug "handle_fetch\n";
  Amailbox.fetch context.!mailbox (write_resp_untagged context.!netw) sequence fetchattr buid >>= function
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist")) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable")) None
  | `Error e -> response context None (Resp_No(None,e)) None
  | `Ok -> response context None (Resp_Ok(None, "FETCH completed")) None

let handle_store context sequence flagsatt flagsval buid =
  Easy.logf `debug "handle_store %d %d\n" (List.length sequence) (List.length flagsval);
  Amailbox.store context.!mailbox (write_resp_untagged context.!netw) sequence flagsatt flagsval buid >>= function
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist")) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable")) None
  | `Error e -> response context None (Resp_No(None,e)) None
  | `Ok ->
    idle_clients context >>= fun () ->
    response context None (Resp_Ok(None, "STORE completed")) None

let handle_copy context sequence mailbox buid =
  Easy.logf `debug "handle_copy %d %s\n" (List.length sequence) mailbox;
  Amailbox.copy context.!mailbox mailbox sequence buid >>= function
  | `NotExists -> response context None (Resp_No(None,"Mailbox doesn't exist")) None
  | `NotSelectable ->  response context None (Resp_No(None,"Mailbox is not selectable")) None
  | `Error e -> response context None (Resp_No(None,e)) None
  | `Ok -> response context None (Resp_Ok(None, "COPY completed")) None

let handle_expunge context =
  Easy.logf `debug "handle_expunge\n";
  Amailbox.expunge context.!mailbox (write_resp_untagged context.!netw) >>= function
  (**
  | `NotExists -> return_resp_ctx None (Resp_No(None,"Mailbox doesn't exist")) None
  | `NotSelectable ->  return_resp_ctx None (Resp_No(None,"Mailbox is not selectable")) None
  **)
  | `Error e -> response context None (Resp_No(None,e)) None
  | `Ok -> response context None (Resp_Ok(None, "EXPUNGE completed")) None

(**
 * Done Selected state
**)

let handle_any context = function
  | Cmd_Id l -> handle_id context l
  | Cmd_Capability -> handle_capability context
  | Cmd_Noop -> handle_noop context
  | Cmd_Logout -> handle_logout  context

let handle_notauthenticated context = function
  | Cmd_Authenticate (a,s) -> handle_authenticate context a s 
  | Cmd_Login (u, p) -> handle_login context u p 
  | Cmd_Starttls -> handle_starttls context
  | Cmd_Lappend (user,mailbox,literal) -> 
      let mbx = Amailbox.create user in
      let context = {context with mailbox = ref mbx} in
      handle_append context mailbox None None literal 

let handle_authenticated context = function
  | Cmd_Select mailbox -> handle_select context mailbox true
  | Cmd_Examine mailbox -> handle_select context mailbox false
  | Cmd_Create mailbox -> handle_create context mailbox 
  | Cmd_Delete mailbox -> handle_delete context mailbox 
  | Cmd_Rename (mailbox,to_mailbox) -> handle_rename context mailbox to_mailbox 
  | Cmd_Subscribe mailbox -> handle_subscribe context mailbox
  | Cmd_Unsubscribe mailbox -> handle_unsubscribe context mailbox 
  | Cmd_List (reference, mailbox) -> handle_list context reference mailbox false
  | Cmd_Lsub (reference, mailbox) -> handle_list context reference mailbox true
  | Cmd_Status (mailbox,optlist) -> handle_status context mailbox optlist 
  | Cmd_Append (mailbox,flags,date,size) -> handle_append context mailbox flags date size 
  | Cmd_Idle -> handle_idle context
  | Cmd_Done -> handle_done context

let handle_selected context = function
  | Cmd_Check -> response context None (Resp_Ok(None, "CHECK completed")) None
  | Cmd_Close -> handle_close context
  | Cmd_Expunge -> handle_expunge context
  | Cmd_Search (charset,search, buid) -> handle_search context charset search buid
  | Cmd_Fetch (sequence,fetchattr, buid) -> handle_fetch context sequence fetchattr buid 
  | Cmd_Store (sequence,flagsatt,flagsval, buid) -> 
      handle_store context sequence flagsatt flagsval buid 
  | Cmd_Copy (sequence,mailbox, buid) -> handle_copy context sequence mailbox buid 

let handle_command context =
  let state = context.!state in
  let command = (Stack.top_exn context.!commands).command in
  match command with
  | Any r -> Easy.logf `debug "handling any\n%!"; handle_any context r
  | Notauthenticated r when state = State_Notauthenticated-> 
    Easy.logf `debug "handling nonauthenticated\n%!"; handle_notauthenticated context r
  | Authenticated r when state = State_Authenticated || state = State_Selected -> 
    Easy.logf `debug "handling authenticated\n%!"; handle_authenticated context r
  | Selected r when state = State_Selected -> 
    Easy.logf `debug "handling selected\n%!"; handle_selected context r
  | Done -> Easy.logf `debug "Done, should log out\n%!"; 
    response context (Some State_Logout) (Resp_Bad(None,"")) None
  | _ -> response context None (Resp_Bad(None, "Bad Command")) None

(* read a line from the network
 * if the line ends with literal {N} and it is not the append
 * then read N bytes, otherwise return the buffer
 *)
let rec read_network reader writer buffer =
  Easy.logf `debug "read_network\n%!";
  Lwt_io.read_line_opt reader >>= function
  | None -> return (`Ok (Buffer.contents buffer))
  | Some buff ->
  (** does command end in the literal {[0-9]+} ? **)
  let i = match_regex_i buff ~regx:"{\\([0-9]+\\)[+]?}$" in
  if i < 0 then (
    Easy.logf `debug "line not ending in literal\n%!";
    Buffer.add_string buffer buff;
    Buffer.add_string buffer "\r\n";
    return (`Ok (Buffer.contents buffer))
  ) else (
    (** literal's size **)
    let len = int_of_string (Str.matched_group 1 buff) in
    (** buffer's content up to the literal **)
    let sub = Str.string_before buff i in
    let literal = Str.string_after buff i in
    Buffer.add_string buffer sub;
    Easy.logf `debug "line is ending in literal %d %s --%s--\n%!" len literal sub;
    if match_regex ~case:false (Buffer.contents buffer) ~regx:append_regex ||
      match_regex ~case:false (Buffer.contents buffer) ~regx:lappend_regex then (
      Easy.logf `debug "handling append\n%!";
      Buffer.add_string buffer literal;
      Buffer.add_string buffer "\r\n";
      return (`Ok (Buffer.contents buffer))
    ) else if ((Buffer.length buffer) + len) > 10240 then (
      Easy.logf `debug "command size is too big: %s\n%!" (Buffer.contents buffer);
      return (`Error "command too long")
    ) else (
      Easy.logf `debug "handling another command with the literal\n%!";
      (if match_regex literal ~regx:"[+]}$" = false then
        write_resp writer (Resp_Cont(""))
      else
        return ()
      ) >>
      let str = String.create len in
      Lwt.pick [
        Lwt_unix.sleep 5.0 >> return `Timeout; 
        Lwt_io.read_into_exactly reader str 0 len >> return (`Ok str)
      ] >>= function
      | `Ok str ->
        Buffer.add_string buffer str;
        read_network reader writer buffer
      | `Timeout ->
        Easy.logf `debug "network timeout\n%!";
        return (`Error "timeout")
    )
  )

let get_command context =
  let open Parsing in
  let open Lexing in
  let open Lex in
  catch (fun () ->
    let buffer = Buffer.create 0 in
    read_network context.!netr context.!netw buffer >>= function
    | `Error err -> return (`Error err)
    | `Ok buff ->
    let lexbuff = Lexing.from_string buff in
    let current_cmd = 
    (
      let current_cmd = (Parser.request (Lex.read (ref `Tag)) lexbuff) in
      Easy.logf `debug "get_request_context, returned from parser\n%!"; Out_channel.flush stdout;
      (* if last command idle then next could only be done *)
      match Stack.top context.!commands with
      |None -> current_cmd
      |Some last_cmd -> 
        if is_idle last_cmd then (
          if is_done current_cmd = false then
            raise ExpectedDone 
          else (*tag from idle goes into done *)
            {current_cmd with tag = last_cmd.tag}
        ) else
          current_cmd
    ) in
    let _ = Stack.pop context.!commands in
    Stack.push context.!commands current_cmd;
    return (`Ok )
  )
  (function 
  | SyntaxError e -> Easy.logf `debug "parse_command error %s\n%!" e; return (`Error (e))
  | Parser.Error -> Easy.logf `debug "parse_command bad command\n%!"; return (`Error ("bad command, parser"))
  | Interpreter.InvalidSequence -> return (`Error ("bad command, invalid sequence"))
  | Dates.InvalidDate -> return (`Error("bad command, invalid date"))
  | ExpectedDone -> return (`Error("Expected DONE"))
  | e -> return (`Error(Exn.backtrace()))
  )

let rec client_requests context =
  catch ( fun () ->
    get_command context >>= function
    | `Error e -> write_resp context.!netw (Resp_Bad(None,e)) >> client_requests context
    | `Ok -> handle_command context >>= fun response ->
      if context.!state = State_Logout then
        return `Done
      else (
        let command = Stack.top_exn context.!commands in
        write_resp context.!netw ~tag:command.tag response >> client_requests context
      )
  )
  (fun _ -> return `Done)