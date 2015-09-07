open Lwt
open Re

exception InvalidCommand

let re = Re_posix.compile_pat "^([0-9]+) (.+)$" 

let opt_val = function
  | None -> raise InvalidCommand
  | Some v -> v

let rec args i repo port =
  if i >= Array.length Sys.argv then
    repo, port
  else
    match Sys.argv.(i) with 
    | "-repo" -> args (i+2) (Some Sys.argv.(i+1)) port
    | "-port" -> args (i+2) repo (Some (int_of_string Sys.argv.(i+1)))
    | _ -> raise InvalidCommand

let commands f =
  try 
    let repo,port = args 1 None None in
    if repo = None || port = None then
      raise InvalidCommand;
    f (opt_val repo) (opt_val port)
  with _ ->
    Printf.printf "usage: maildir_read -repo [repo location] -port [port number]\n%!"

let try_close cio =
  catch (fun () -> Lwt_io.close cio)
  (function _ -> return ())

let try_close_sock sock =
  catch (fun () -> Lwt_unix.close sock)
  (function _ -> return ())


let init_socket ?(stype=Unix.SOCK_STREAM) addr port =
  let sockaddr = Unix.ADDR_INET (Unix.inet_addr_of_string addr, port) in
  let socket = Lwt_unix.socket Unix.PF_INET stype 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_unix.bind socket sockaddr;
  return socket

let create_srv_socket addr port =
  init_socket addr port >>= fun socket ->
  Lwt_unix.listen socket 10;
  return socket

let accept_cmn sock =
  Lwt_unix.accept sock >>= fun (sock_c, addr) ->
  let ic = Lwt_io.of_fd ~close:(fun()->return()) ~mode:Lwt_io.input sock_c in
  let oc = Lwt_io.of_fd ~close:(fun()->return()) ~mode:Lwt_io.output sock_c in
  return (sock_c,(ic,oc))

let server addr port f =
  create_srv_socket addr port >>= fun sock ->
  let rec connect f sock =
    accept_cmn sock >>= fun (sock_c,(netr,netw)) ->
    async ( fun () ->
      catch( fun () ->
        f netr netw >>= fun () ->
        try_close netr >>= fun () -> try_close netw >>= fun () -> try_close_sock sock_c
      ) 
      (fun ex -> try_close netr >>= fun () -> try_close netw >>= fun () -> try_close_sock sock_c
      >>= fun () -> Printf.printf "exception %s\n%!" (Printexc.to_string ex);
      return ()
      )
    ); connect f sock 
  in
  connect f sock 

let read_uidlst file =
  Lwt_io.with_file file ~mode:Lwt_io.Input (fun ic ->
    let rec read uids =
      Lwt_io.read_line_opt ic >>= function
        | Some l ->
          let subs = Re.exec re l in
          let uid = int_of_string (Re.get subs 1) in
          let file = Re.get subs 2 in
          read ((uid,file) :: uids)
        | None -> return (List.rev uids)
    in
    read []
  )

let read_message file w =
  Lwt_io.with_file file ~mode:Lwt_io.Input (fun ic ->
    let rec read () =
      catch (fun () ->
        Lwt_io.read ~count:1024 ic >>= fun buff ->
        if buff <> "" then (
          Lwt_io.write w buff >>= fun () ->
          read ()
        ) else
          return ()
      ) (fun ex -> Printf.printf "exc: %s" (Printexc.to_string ex); return ())
    in
    read ())

let read_files repo w =
  let uidlst_file = Filename.concat repo "imaplet.uidlst" in
  read_uidlst uidlst_file >>= fun uids ->
  Lwt_list.iter_s (fun (uid,file) ->
    Printf.printf "%d\n%!" uid;
    let file = Filename.concat (Filename.concat repo "cur") file in
    read_message file w 
  ) uids

let () =
  commands (fun repo port ->
    Lwt_main.run (
      server "0.0.0.0" port (fun r w ->
        let rec loop () =
          Lwt_io.read_line_opt r >>= function
          | Some l ->
            if l = "read" then (
              let t = Unix.gettimeofday () in
              read_files repo w >>= fun () ->
              Printf.printf "total time %.04f\n%!" (Unix.gettimeofday() -. t);
              loop ()
            ) else (
              return ()
            )
          | None -> return ()
        in
        loop ()
      )
    )
  )
