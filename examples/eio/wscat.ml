open Eio.Std

let websocket_handler env ~sw u wsd =
  let stdin = Eio.Stdenv.stdin env in
  let rec input_loop buf wsd () =
      let line = Eio.Buf_read.line buf in
      traceln "> %s" line;
      let payload = Bytes.of_string line in
      Websocketaf.Wsd.send_bytes wsd ~kind:`Text payload ~off:0 ~len:(Bytes.length payload);
      if line = "exit" then begin
        Websocketaf.Wsd.close wsd;
      end else
        input_loop buf wsd ()
  in
  let buf = Eio.Buf_read.of_flow stdin ~initial_size:100 ~max_size:1_000_000 in
  Eio.Fiber.fork ~sw (input_loop buf wsd);
  let frame ~opcode:_ ~is_fin:_ ~len:_ payload =
    Websocketaf.Payload.schedule_read payload
      ~on_eof:ignore
      ~on_read:(fun bs ~off ~len ->
    let payload = Bytes.create len in
    Bigstringaf.blit_to_bytes bs ~src_off:off payload ~dst_off:0 ~len;
    Format.printf "%s@." (Bytes.unsafe_to_string payload);)
  in

  let eof () =
    Printf.eprintf "[EOF]\n%!";
    Promise.resolve u ()
  in
  { Websocketaf.Websocket_connection.frame
  ; eof
  }

let error_handler = function
  | `Handshake_failure (rsp, _body) ->
    Format.eprintf "Handshake failure: %a\n%!" Httpaf.Response.pp_hum rsp
  | _ -> assert false

let () =
  let host = ref None in
  let port = ref 80 in

  Arg.parse
    ["-p", Set_int port, " Port number (80 by default)"]
    (fun host_argument -> host := Some host_argument)
    "wscat.exe [-p N] HOST";

  let host =
    match !host with
    | None -> failwith "No hostname provided"
    | Some host -> host
  in

  Eio_main.run (fun env ->
    Switch.run (fun sw ->
      let net = Eio.Stdenv.net env in
      let addresses =
        List.filter_map
          (function
            | `Tcp (addr, _port) ->
              let addr = Eio.Net.Ipaddr.fold ~v4:(Option.some) ~v6:(Fun.const None) addr
              in
              Option.map (fun addr ->
                `Tcp (addr, !port)) addr
            | _ -> None)
          (Eio.Net.getaddrinfo net host)
      in

      let socket = Eio.Net.connect ~sw net (List.hd addresses) in

      let p, u = Promise.create () in
      let nonce = "0123456789ABCDEF" in
      let resource = "/" in
      let port = !port in
      let _client : Websocketaf_eio.Client.t = Websocketaf_eio.Client.connect
        socket
        ~sw
        ~nonce
        ~host
        ~port
        ~resource
        ~error_handler
        ~websocket_handler:(websocket_handler env ~sw u)
      in
      Promise.await p))
