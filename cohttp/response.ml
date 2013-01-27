(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
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
 *
 *)

module Make(IO:Make.IO) = struct

  module Header_IO = Header_io.Make(IO)
  module Transfer_IO = Transfer_io.Make(IO)

  type ic = IO.ic
  type oc = IO.oc
  type 'a io = 'a IO.t
  open IO
  let (>>=) = (>>=)

  type t = {
    encoding: Transfer.encoding;
    headers: Header.t;
    version: Code.version;
    status: Code.status_code;
  }

  let version r = r.version
  let status r = r.status
  let headers r = r.headers

  let make ?(version=`HTTP_1_1) ?(status=`OK) ?(encoding=Transfer.Chunked) ?headers () =
    let headers = match headers with None -> Header.init () |Some h -> h in
    { encoding; headers; version; status }

  let pieces_sep = Re_str.regexp_string " "
  let header_sep = Re_str.regexp ": *"
  
  let parse_response_fst_line ic =
    let open Code in
    read_line ic >>= function
    |Some response_line -> begin
      match Re_str.split_delim pieces_sep response_line with
      | version_raw :: code_raw :: _ -> begin
         match version_of_string version_raw with
         |Some v -> return (Some (v, (status_of_code (int_of_string code_raw))))
         |_ -> return None
      end
      | _ -> return None
    end
    |None -> return None
 
  let read ic =
    parse_response_fst_line ic >>= function
    |None -> return None
    |Some (version, status) ->
       Header_IO.parse ic >>= fun headers ->
       let encoding = Header.get_transfer_encoding headers in
       return (Some { encoding; headers; version; status })

  let has_body r = Transfer.has_body r.encoding
  let read_body req fn ic = 
    let rec aux () =
      Transfer_IO.read req.encoding ic
      >>= function
      |Transfer.Done -> fn None; return ()
      |Transfer.Final_chunk b -> fn (Some b); fn None; return ()
      |Transfer.Chunk b -> fn (Some b); aux () 
    in aux () 

  let write_header res oc =
    write oc (Printf.sprintf "%s %s\r\n" (Code.string_of_version res.version) 
      (Code.string_of_status res.status)) >>= fun () ->
    let headers = Header.add_transfer_encoding res.headers res.encoding in
    iter (IO.write oc) (Header.to_lines headers) >>= fun () ->
    IO.write oc "\r\n"

  let write_body req oc buf =
    Transfer_IO.write req.encoding oc buf

  let write_footer req oc =
    match req.encoding with
    |Transfer.Chunked ->
       (* TODO Trailer header support *)
       IO.write oc "0\r\n\r\n"
    |Transfer.Fixed _ | Transfer.Unknown -> return ()

  let write fn req oc =
    let rec aux () =
      match fn () with
      |Some buf ->
         IO.write oc buf >>= fun () ->
         aux ()
      |None -> IO.return ()
    in 
    write_header req oc >>= fun () ->
    aux () >>= fun () ->
    write_footer req oc
end
