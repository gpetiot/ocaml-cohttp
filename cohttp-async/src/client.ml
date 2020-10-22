open Base
open Async_kernel
open Async_unix

module Request = struct
  include Cohttp.Request
  include (Make(Io) : module type of Make(Io) with type t := t)
end

module Response = struct
  include Cohttp.Response
  include (Make(Io) : module type of Make(Io) with type t := t)
end

module Net = struct

  let lookup uri =
    let host = Uri.host_with_default ~default:"localhost" uri in
    match Uri_services.tcp_port_of_uri ~default:"http" uri with
    | None -> Deferred.Or_error.error_string
                "Net.lookup: failed to get TCP port form Uri"
    | Some port ->
      let open Unix in
      Addr_info.get ~host [ Addr_info.AI_FAMILY PF_INET
                          ; Addr_info.AI_SOCKTYPE SOCK_STREAM]
      >>| function
      | { Addr_info.ai_addr=ADDR_INET (addr,_); _ }::_ ->
        Or_error.return (host, Ipaddr_unix.of_inet_addr addr, port)
      | _ -> Or_error.error "Failed to resolve Uri" uri Uri_sexp.sexp_of_t

  let connect_uri ?ssl_ctx uri =
    match (Uri.scheme uri, ssl_ctx) with
    | Some "httpunix", _ ->
      let host = Uri.host_with_default ~default:"localhost" uri in
      let tcp_cfg = Conduit_async.TCP.Unix (Socket.Address.Unix.create host) in
      Conduit_async.connect tcp_cfg Conduit_async.TCP.protocol
    | Some "https", Some ctx ->
      lookup uri
      |> Deferred.Or_error.ok_exn
      >>= fun (_, addr, port) ->
      let tcp_cfg =
        let addr = Ipaddr_unix.to_inet_addr addr in
        Conduit_async.TCP.Inet (Socket.Address.Inet.create addr ~port) in
      Conduit_async.connect (ctx, tcp_cfg) Conduit_async_ssl.TCP.protocol
    | Some "https", None ->
      lookup uri
      |> Deferred.Or_error.ok_exn
      >>= fun (host, addr, port) ->
      let tcp_cfg =
        let addr = Ipaddr_unix.to_inet_addr addr in
        Conduit_async.TCP.Inet (Socket.Address.Inet.create addr ~port) in
      let ctx = Conduit_async_ssl.context ~hostname:host () in
      Conduit_async.connect (ctx, tcp_cfg) Conduit_async_ssl.TCP.protocol
    | _ ->
      lookup uri
      |> Deferred.Or_error.ok_exn
      >>= fun (_, addr, port) ->
      let tcp_cfg =
        let addr = Ipaddr_unix.to_inet_addr addr in
        Conduit_async.TCP.Inet (Socket.Address.Inet.create addr ~port) in
      Conduit_async.connect tcp_cfg Conduit_async.TCP.protocol

  let failwith fmt = Stdlib.Format.kasprintf failwith fmt

  let connect_uri ?ssl_ctx uri =
    connect_uri ?ssl_ctx uri >>= function
    | Ok flow -> Conduit_async.reader_and_writer_of_flow flow
    | Error err -> failwith "%a" Conduit_async.pp_error err
end

let read_response ic =
  Response.read ic >>| function
  | `Eof -> failwith "Connection closed by remote host"
  | `Invalid reason -> failwith reason
  | `Ok res ->
    begin
      match Response.has_body res with
      | `Yes | `Unknown ->
        (* Build a response pipe for the body *)
        let reader = Response.make_body_reader res ic in
        let pipe = Body_raw.pipe_of_body Response.read_body_chunk reader in
        (res, pipe)
      | `No ->
        let pipe = Pipe.of_list [] in
        (res, pipe)
    end

let request ?ssl_ctx ?uri ?(body=`Empty) req =
  (* Connect to the remote side *)
  let uri =
    match uri with
    | Some t -> t
    | None -> Request.uri req in
  Net.connect_uri ?ssl_ctx uri >>= fun (ic, oc) ->
  try_with (fun () ->
      Request.write (fun writer ->
          Body_raw.write_body Request.write_body body writer) req oc
      >>= fun () ->
      read_response ic >>| fun (resp, body) ->
      don't_wait_for (
        Pipe.closed body >>= fun () ->
        Deferred.all_unit [Reader.close ic; Writer.close oc]);
      (resp, `Pipe body)) >>= begin function
    | Ok res -> return res
    | Error e ->
      don't_wait_for (Reader.close ic);
      don't_wait_for (Writer.close oc);
      raise e
  end

let callv ?ssl_ctx uri reqs =
  let reqs_c = ref 0 in
  let resp_c = ref 0 in
  Net.connect_uri ?ssl_ctx uri >>= fun (ic, oc) ->
  try_with (fun () ->
      reqs
      |> Pipe.iter ~f:(fun (req, body) ->
          Int.incr reqs_c;
          Request.write (fun w -> Body_raw.write_body Request.write_body body w)
            req oc)
      |> don't_wait_for;
      let last_body_drained = ref Deferred.unit in
      let responses = Reader.read_all ic (fun ic ->
          !last_body_drained >>= fun () ->
          if Pipe.is_closed reqs && (!resp_c >= !reqs_c) then
            return `Eof
          else
            ic |> read_response >>| fun (resp, body) ->
            Int.incr resp_c;
            last_body_drained := Pipe.closed body;
            `Ok (resp, `Pipe body)
        ) in
      don't_wait_for (
        Pipe.closed reqs >>= fun () ->
        Pipe.closed responses >>= fun () ->
        Writer.close oc
      );
      return responses)
  >>= begin function
    | Ok x -> return x
    | Error e ->
      don't_wait_for (Reader.close ic);
      don't_wait_for (Writer.close oc);
      raise e
  end

let call ?ssl_ctx ?headers ?(chunked=false) ?(body=`Empty) meth uri =
  (* Create a request, then make the request. Figure out an appropriate
     transfer encoding *)
  begin
    match chunked with
    | false ->
      Body_raw.disable_chunked_encoding body >>| fun (body, body_length) ->
      Request.make_for_client ?headers ~chunked ~body_length meth uri, body
    | true -> begin
        Body.is_empty body >>| function
        | true -> (* Don't used chunked encoding with an empty body *)
          Request.make_for_client ?headers ~chunked:false ~body_length:0L meth uri, body
        | false -> (* Use chunked encoding if there is a body *)
          Request.make_for_client ?headers ~chunked:true meth uri, body
      end
  end >>= fun (req, body) -> request ?ssl_ctx ~body ~uri req

let get ?ssl_ctx ?headers uri =
  call ?ssl_ctx ?headers ~chunked:false `GET uri

let head ?ssl_ctx ?headers uri =
  call ?ssl_ctx ?headers ~chunked:false `HEAD uri
  >>| fun (res, body) ->
  (match body with
   | `Pipe p -> Pipe.close_read p;
   | _ -> ());
  res

let post ?ssl_ctx ?headers ?(chunked=false) ?body uri =
  call ?ssl_ctx ?headers ~chunked ?body `POST uri

let post_form ?ssl_ctx ?headers ~params uri =
  let headers = Cohttp.Header.add_opt_unless_exists headers
      "content-type" "application/x-www-form-urlencoded" in
  let body = Body.of_string (Uri.encoded_of_query params) in
  post ?ssl_ctx ~headers ~chunked:false ~body uri

let put ?ssl_ctx ?headers ?(chunked=false) ?body uri =
  call ?ssl_ctx ?headers ~chunked ?body `PUT uri

let patch ?ssl_ctx ?headers ?(chunked=false) ?body uri =
  call ?ssl_ctx ?headers ~chunked ?body `PATCH uri

let delete ?ssl_ctx ?headers ?(chunked=false) ?body uri =
  call ?ssl_ctx ?headers ~chunked ?body `DELETE uri