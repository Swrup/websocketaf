let sha1 s =
  s
  |> Digestif.SHA1.digest_string
  |> Digestif.SHA1.to_raw_string

let connection_handler =
  let module Body = Httpaf.Body in
  let module Headers = Httpaf.Headers in
  let module Reqd = Httpaf.Reqd in
  let module Response = Httpaf.Response in
  let module Status = Httpaf.Status in

  let websocket_handler _client_address wsd =
    let frame ~opcode ~is_fin:_ ~len:_ payload =
      match (opcode: Websocketaf.Websocket.Opcode.t) with
      | #Websocketaf.Websocket.Opcode.standard_non_control as opcode ->
        Websocketaf.Payload.schedule_read payload
          ~on_eof:ignore
          ~on_read:(fun bs ~off ~len ->
          Websocketaf.Wsd.schedule wsd bs ~kind:opcode ~off ~len)
      | `Connection_close ->
        Websocketaf.Wsd.close wsd
      | `Ping ->
        Websocketaf.Wsd.send_pong wsd
      | `Pong
      | `Other _ ->
        ()
    in
    let eof () =
      Format.eprintf "EOF\n%!";
      Websocketaf.Wsd.close wsd
    in
    { Websocketaf.Websocket_connection.frame
    ; eof
    }
  in

  let error_handler wsd (`Exn exn) =
    let message = Printexc.to_string exn in
    let payload = Bytes.of_string message in
    Websocketaf.Wsd.send_bytes wsd ~kind:`Text payload ~off:0
      ~len:(Bytes.length payload);
    Websocketaf.Wsd.close wsd
  in
  let http_error_handler _client_address ?request:_ error handle =
    let message =
      match error with
      | `Exn exn -> Printexc.to_string exn
      | (#Status.client_error | #Status.server_error) as error -> Status.to_string error
    in
    let body = handle Headers.empty in
    Body.Writer.write_string body message;
    Body.Writer.close body
  in
  let upgrade_handler addr upgrade () =
    let ws_conn =
      Websocketaf.Server_connection.create_websocket
        ~error_handler
        (websocket_handler addr)
    in
    upgrade
      (Gluten.make (module Websocketaf.Server_connection) ws_conn)
  in
  let request_handler addr (reqd : Httpaf.Reqd.t Gluten.Reqd.t) =
    Format.eprintf  "REQ@.";
    let { Gluten.Reqd.reqd; upgrade  } = reqd in
    match Websocketaf.Handshake.respond_with_upgrade ~sha1 reqd (upgrade_handler addr upgrade) with
    | Ok () -> ()
    | Error err_str ->
        let response = Response.create
        ~headers:(Httpaf.Headers.of_list ["Connection", "close"])
        `Bad_request
    in
      Reqd.respond_with_string reqd response err_str
  in
  Httpaf_eio.Server.create_connection_handler
    ?config:None
    ~request_handler
    ~error_handler:http_error_handler

let () =
  let port = ref 8080 in
  Arg.parse
    ["-p", Arg.Set_int port, " Listening port number (8080 by default)"]
    ignore
    "Echoes websocket messages. Runs forever.";

  let listen_address = (`Tcp (Eio.Net.Ipaddr.V4.loopback, !port)) in
  Eio_main.run (fun env ->
    let network = Eio.Stdenv.net env in
    Eio.Switch.run (fun sw ->
      let socket =
        Eio.Net.listen ~reuse_addr:true  ~reuse_port:true ~backlog:5 ~sw
        network
        listen_address
      in
    let domain_mgr = Eio.Stdenv.domain_mgr env in
    let p, _ = Eio.Promise.create () in
    for _i = 1 to Domain.recommended_domain_count () do
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Domain_manager.run domain_mgr (fun () ->
          Eio.Switch.run (fun sw ->
            while true do
              Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> assert false) (fun client_sock client_addr ->
                  (* let p, u = Eio.Promise.create () in *)
                  connection_handler ~sw client_addr client_sock)
            done;
          `Stop_daemon)))
    done;
    Eio.Promise.await p))
