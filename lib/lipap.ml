open Rresult
open Ptt_tuyau.Lwt_backend
open Lwt.Infix

module Make
    (Random : Mirage_random.S)
    (Time : Mirage_time.S)
    (Mclock : Mirage_clock.MCLOCK)
    (Pclock : Mirage_clock.PCLOCK)
    (Resolver : Ptt.Sigs.RESOLVER with type +'a io = 'a Lwt.t)
    (Stack : Mirage_stack.V4V6) =
struct
  include Ptt_tuyau.Make (Stack)

  let src = Logs.Src.create "lipap"

  module Log : Logs.LOG = (val Logs.src_log src)

  module Random = struct
    type g = Random.g
    type +'a io = 'a Lwt.t

    let generate ?g buf =
      let len = Bytes.length buf in
      let raw = Random.generate ?g len in
      Cstruct.blit_to_bytes raw 0 buf 0 len
      ; Lwt.return ()
  end

  module Submission =
    Ptt.Submission.Make (Lwt_scheduler) (Lwt_io) (TLSFlow) (Resolver) (Random)

  module Server = Ptt_tuyau.Server (Time) (Stack)
  include Ptt_transmit.Make (Pclock) (Stack) (Submission.Md)

  let smtp_submission_service ?stop ~port stack resolver random hash conf_server
      =
    let tls = (Submission.info conf_server).Ptt.SSMTP.tls in
    Server.init ~port stack >>= fun service ->
    let handler flow =
      let ip, port = Stack.TCP.dst flow in
      Lwt.catch
        (fun () ->
          TLSFlow.server flow tls >>= fun v ->
          Submission.accept ~ipaddr:ip v resolver random hash conf_server
          >|= R.reword_error (R.msgf "%a" Submission.pp_error)
          >>= fun res ->
          TLSFlow.close v >>= fun () ->
          Stack.TCP.close flow >>= fun () -> Lwt.return res)
        (function
          | Failure err -> Lwt.return (R.error_msg err)
          | exn -> Lwt.return (Error (`Exn exn)))
      >>= function
      | Ok () ->
        Log.info (fun m -> m "<%a:%d> quit properly" Ipaddr.pp ip port)
        ; Lwt.return ()
      | Error (`Msg err) ->
        Log.err (fun m -> m "<%a:%d> %s" Ipaddr.pp ip port err)
        ; Lwt.return ()
      | Error (`Exn exn) ->
        Log.err (fun m ->
            m "<%a:%d> raised an unknown exception: %s" Ipaddr.pp ip port
              (Printexc.to_string exn))
        ; Lwt.return () in
    let (`Initialized fiber) = Server.serve_when_ready ?stop ~handler service in
    fiber

  let smtp_logic ~info ~tls stack resolver messaged map =
    let rec go () =
      Submission.Md.await messaged >>= fun () ->
      Submission.Md.pop messaged >>= function
      | None -> Lwt.pause () >>= go
      | Some ((key, _, _) as v) ->
        let transmit () =
          Submission.resolve_recipients ~domain:info.Ptt.SSMTP.domain resolver
            map
            (List.map fst (Ptt.Messaged.recipients key))
          >>= fun recipients -> transmit ~info ~tls stack v recipients in
        Lwt.async transmit
        ; Lwt.pause () >>= go in
    go ()

  let fiber
      ?stop
      ~port
      ~tls
      stack
      resolver
      random
      hash
      map
      info
      authenticator
      mechanisms =
    let conf_server = Submission.create ~info ~authenticator mechanisms in
    let messaged = Submission.messaged conf_server in
    Lwt.join
      [
        smtp_submission_service ?stop ~port stack resolver random hash
          conf_server; smtp_logic ~info ~tls stack resolver messaged map
      ]
end
