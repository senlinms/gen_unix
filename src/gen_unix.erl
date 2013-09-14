%% Copyright (c) 2013, Michael Santos <michael.santos@gmail.com>
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% Redistributions of source code must retain the above copyright
%% notice, this list of conditions and the following disclaimer.
%%
%% Redistributions in binary form must reproduce the above copyright
%% notice, this list of conditions and the following disclaimer in the
%% documentation and/or other materials provided with the distribution.
%%
%% Neither the name of the author nor the names of its contributors
%% may be used to endorse or promote products derived from this software
%% without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.
-module(gen_unix).
-include_lib("procket/include/procket.hrl").
-include_lib("procket/include/procket_msg.hrl").
%-include_lib("pkt/include/pkt.hrl").

-export([
    listen/1,
    connect/1,
    close/1,

    accept/1,

    msg/1,

    fdrecv/2,
    fd/1,

    credrecv/2,
    cred/1,

    sendmsg/2, sendmsg/3,
    recvmsg/2, recvmsg/3,

    scm_rights/0,
    scm_creds/0,
    scm_timestamp/0,
    scm_bintime/0,
    so_passcred/0,
    so_peercred/0
    ]).

-define(SCM_RIGHTS, gen_unix:scm_rights()).
-define(SCM_CREDENTIALS, ?SCM_CREDS).
-define(SCM_CREDS, gen_unix:scm_creds()).
-define(SCM_TIMESTAMP, gen_unix:scm_timestamp()).
-define(SCM_BINTIME, gen_unix:scm_bintime()).

% XXX testing only, move these to procket
-define(SO_PASSCRED, gen_unix:so_passcred()).
-define(SO_PEERCRED, gen_unix:so_peercred()).


listen(Path) when is_list(Path) ->
    listen(list_to_binary(Path));
listen(Path) when is_binary(Path), byte_size(Path) < ?UNIX_PATH_MAX ->
    {ok, Socket} = procket:socket(?PF_LOCAL, ?SOCK_STREAM, 0),
    Len = byte_size(Path),
    Sun = <<(procket:sockaddr_common(?PF_LOCAL, Len))/binary,
            Path/binary,
            0:((procket:unix_path_max()-Len)*8)>>,
    ok = procket:bind(Socket, Sun),
    ok = procket:listen(Socket, ?BACKLOG),
    {ok, Socket}.

connect(Path) when is_list(Path) ->
    connect(list_to_binary(Path));
connect(Path) when is_binary(Path), byte_size(Path) < ?UNIX_PATH_MAX ->
    {ok, Socket} = procket:socket(?PF_LOCAL, ?SOCK_STREAM, 0),
    Len = byte_size(Path),
    Sun = <<(procket:sockaddr_common(?PF_LOCAL, Len))/binary,
            Path/binary,
            0:((procket:unix_path_max()-Len)*8)>>,
    ok = procket:connect(Socket, Sun),
    {ok, Socket}.

close(FD) ->
    procket:close(FD).

accept(FD) ->
    procket:accept(FD).

cmsghdr(Level, Type, Data) when is_integer(Level), is_integer(Type), is_binary(Data) ->
    procket_msg:cmsghdr(#cmsghdr{
            level = Level,
            type = Type,
            data = Data
            }).

msghdr(Name, Iov, Cmsg) ->
    {ok, Msg, Res} = procket_msg:msghdr(#msghdr{
        name = Name,        % must be empty (NULL) or eisconn
        iov = Iov,          % send 1 byte to differentiate success from EOF
        control = Cmsg
    }),
    {ok, {msghdr, Msg, Res}}.

msg({fd, send, FD}) when is_integer(FD); is_list(FD) ->
    Cmsg = cmsghdr(sol_socket(), ?SCM_RIGHTS, fd(FD)),
    msghdr(<<>>, [<<"x">>], Cmsg);
msg({cred, send}) ->
    Cmsg = case os:type() of
        {unix,linux} ->
            % Linux fills in the cmsghdr
            <<>>;
        {unix,_} ->
	        % FreeBSD requires the cmsghdrcred to be allocated but
	        % fills in the fields
            cmsghdr(sol_socket(), ?SCM_CREDENTIALS, cred([]))
    end,
    msghdr(<<>>, [<<"c">>], Cmsg);

msg({fd, recv}) ->
    msg({fd, recv, 1});
msg({fd, recv, N}) when is_integer(N) ->
    Cmsg = cmsghdr(sol_socket(), 0, <<0:(N * 4 * 8)>>),
    msghdr(<<>>, [<<0:8>>], Cmsg);
msg({cred, recv}) ->
    Cmsg = cmsghdr(sol_socket(), ?SCM_CREDENTIALS, <<0:(sizeof(ucred) * 8)>>),
    msghdr(<<>>, [<<0:8>>], Cmsg).

fdrecv(Socket, {msghdr, Msg, Res}) when is_integer(Socket), is_binary(Msg), is_list(Res) ->
    case recvmsg(Socket, Msg) of
        {ok, 1, _Msghdr} ->
            Control = proplists:get_value(msg_control, Res),
            {ok, Buf} = procket:buf(Control),
            {ok, Data} = cmsghdr_data(Buf, sol_socket(), ?SCM_RIGHTS),
            {ok, fd(Data)};
        % XXX EOF?
        {ok, 0, _Msghdr} ->
            {ok, []};
        {error, _} = Error ->
            Error
    end.

credrecv(Socket, {msghdr, Msg, Res}) when is_integer(Socket) ->
    ok = setsockopt(Socket, credrecv, open),
    Reply = case recvmsg(Socket, Msg) of
        {ok, 1, _Msghdr} ->
            Control = proplists:get_value(msg_control, Res),
            {ok, Buf} = procket:buf(Control),
            {ok, Data} = cmsghdr_data(Buf, sol_socket(), ?SCM_CREDENTIALS),
            {ok, cred(Data)};
        % XXX EOF?
        {ok, 0, _Msghdr} ->
            {ok, []};
        {error, _} = Error ->
            Error
    end,
    ok = setsockopt(Socket, credrecv, close),
    Reply.

cmsghdr_data(Buf, Level, Type) ->
    {Cmsg, _} = procket_msg:cmsghdr(Buf),
    case Cmsg of
        #cmsghdr{level = Level, type = Type, data = Data} ->
            {ok, Data};
        _ ->
            {error, einval}
    end.

fd(FDs) when is_binary(FDs) ->
    [ FD || <<FD:4/native-unsigned-integer-unit:8>> <= FDs ];
fd(FDs) when is_list(FDs) ->
    << <<FD:4/native-unsigned-integer-unit:8>> || FD <- FDs >>.

cred(Data) ->
    cred(os:type(), Data).

% struct ucred
% {
%     pid_t pid;            /* PID of sending process.  */
%     uid_t uid;            /* UID of sending process.  */
%     gid_t gid;            /* GID of sending process.  */
% };
cred({unix, linux}, <<
        Pid:4/native-signed-integer-unit:8,
        Uid:4/native-unsigned-integer-unit:8,
        Gid:4/native-unsigned-integer-unit:8
        >>) ->
    [{pid, Pid}, {uid, Uid}, {gid, Gid}];
cred({unix, linux}, Fields) when is_list(Fields) ->
    Pid = proplists:get_value(pid, Fields, list_to_integer(os:getpid())),
    Uid = proplists:get_value(uid, Fields, 0), % XXX no way to get uid?
    Gid = proplists:get_value(gid, Fields, 0), % XXX or gid?
    <<Pid:4/native-signed-integer-unit:8,
      Uid:4/native-unsigned-integer-unit:8,
      Gid:4/native-unsigned-integer-unit:8>>;

% #define CMGROUP_MAX 16
% struct cmsgcred {
%     pid_t   cmcred_pid;             /* PID of sending process */
%     uid_t   cmcred_uid;             /* real UID of sending process */
%     uid_t   cmcred_euid;            /* effective UID of sending process */
%     gid_t   cmcred_gid;             /* real GID of sending process */
%     short   cmcred_ngroups;         /* number or groups */
%     gid_t   cmcred_groups[CMGROUP_MAX];     /* groups */
% };
cred({unix, freebsd}, <<
        Pid:4/native-unsigned-integer-unit:8,
        Uid:4/native-unsigned-integer-unit:8,
        Euid:4/native-unsigned-integer-unit:8,
        Gid:4/native-unsigned-integer-unit:8,
        Ngroups:2/native-signed-integer-unit:8,
        Rest/binary
        >>) ->
    Pad = procket:wordalign(4 + 4 + 4 + 4 + 2) * 8,
    Num = Ngroups * 4, % gid_t is 4 bytes
    <<_:Pad, Gr:Num/bytes, _/binary>> = Rest,
    Groups = [ N || <<N:4/native-unsigned-integer-unit:8>> <= Gr ],
    [{pid, Pid}, {uid, Uid}, {euid, Euid}, {gid, Gid}, {groups, Groups}];
cred({unix, freebsd}, Fields) when is_list(Fields) ->
    Size = erlang:system_info({wordsize, external}),
    Pid = proplists:get_value(pid, Fields, list_to_integer(os:getpid())),
    Uid = proplists:get_value(uid, Fields, 0),
    Euid = proplists:get_value(euid, Fields, 0),
    Gid = proplists:get_value(gid, Fields, 0),
    Groups = proplists:get_value(groups, Fields, [0]),
    Pad0 = procket:wordalign(4 + 4 + 4 + 4 + 2) * 8,
    Ngroups = length(Groups),
    Gr = << <<N:4/native-unsigned-integer-unit:8>> || N <- Groups >>,
    Pad1 = (16 - Ngroups) * 4 * 8,
    <<Pid:4/native-unsigned-integer-unit:8,
      Uid:4/native-unsigned-integer-unit:8,
      Euid:4/native-unsigned-integer-unit:8,
      Gid:4/native-unsigned-integer-unit:8,
      Ngroups:2/native-signed-integer-unit:8,
      0:Pad0,
      Gr/binary, 0:Pad1,
      0:Size/native-unsigned-integer-unit:8>>;

% OpenBSD
% struct ucred {
%     u_int   cr_ref;         /* reference count */
%     uid_t   cr_uid;         /* effective user id */
%     gid_t   cr_gid;         /* effective group id */
%     short   cr_ngroups;     /* number of groups */
%     gid_t   cr_groups[NGROUPS]; /* groups */
% };
%
% NetBSD
% struct uucred {
%     unsigned short  cr_unused;      /* not used, compat */
%     uid_t       cr_uid;         /* effective user id */
%     gid_t       cr_gid;         /* effective group id */
%     short       cr_ngroups;     /* number of groups */
%     gid_t       cr_groups[NGROUPS_MAX]; /* groups */
% };
cred({unix, _}, <<
        Ref:4/native-unsigned-integer-unit:8,
        Uid:4/native-unsigned-integer-unit:8,
        Gid:4/native-unsigned-integer-unit:8,
        Ngroups:2/native-signed-integer-unit:8,
        Rest/binary
        >>) ->
    Num = Ngroups * 4 * 8,
    <<Gr:Num, _/binary>> = Rest,
    Groups = [ N || <<N:4/native-unsigned-integer-unit:8>> <= Gr ],
    [{ref, Ref}, {uid, Uid}, {gid, Gid}, {groups, Groups}];
cred({unix, _}, Fields) when is_list(Fields) ->
    Ref = proplists:get_value(ref, Fields, 0),
    Uid = proplists:get_value(uid, Fields, 0),
    Gid = proplists:get_value(gid, Fields, 0),
    Groups = proplists:get_value(groups, Fields, [0]),
    Ngroups = length(Groups),
    Gr = << <<N:4/native-unsigned-integer-unit:8>> || N <- Groups >>,
    Pad = (16 - Ngroups) * 8, % NGROUPS_MAX = 16
    <<Ref:4/native-unsigned-integer-unit:8,
      Uid:4/native-unsigned-integer-unit:8,
      Gid:4/native-unsigned-integer-unit:8,
      Ngroups:2/native-signed-integer-unit:8,
      Gr/binary, 0:Pad>>.


scm_rights() ->
    16#01.

scm_creds() ->
    scm_creds(os:type()).
scm_creds({unix,linux}) -> 16#02;
scm_creds({unix,freebsd}) -> 16#03;
scm_creds({unix,netbsd}) -> 16#04;
% OpenBSD uses getsockopt(SOL_SOCKET, SO_PEERCRED
% XXX Return undefined or {error, unsupported}?
scm_creds(_) -> undefined.

scm_timestamp() ->
    scm_timestamp(os:type()).
scm_timestamp({unix,freebsd}) -> 16#02;
scm_timestamp({unix,netbsd}) -> 16#08;
scm_timestamp(_) -> undefined.

scm_bintime() ->
    scm_bintime(os:type()).
scm_bintime({unix,freebsd}) -> 16#04;
scm_bintime(_) -> undefined.

so_passcred() ->
    so_passcred(os:type()).
so_passcred({unix,linux}) -> 16;
so_passcred(_) -> undefined.

so_peercred() ->
    so_peercred(os:type()).
so_peercred({unix,openbsd}) -> 16#1022;
so_peercred(_) -> undefined.

sol_socket() ->
    sol_socket(os:type()).
sol_socket({unix,linux}) -> 1;
sol_socket({unix,_}) -> 16#ffff.

sizeof(ucred) ->
    sizeof(os:type(), ucred).
sizeof({unix,linux}, ucred) ->
    4 + 4 + 4;
sizeof({unix,_}, ucred) ->
    Len = 4 + 4 + 4 + 4 + 2,
    Pad = procket:wordalign(Len),
    Len + Pad + 4 * 16.

setsockopt(Socket, credrecv, Status) ->
    setsockopt(os:type(), Socket, credrecv, Status).
setsockopt({unix,linux}, Socket, credrecv, open) ->
    procket:setsockopt(Socket, sol_socket(), ?SO_PASSCRED,
        <<1:4/native-unsigned-integer-unit:8>>);
setsockopt({unix,linux}, Socket, credrecv, close) ->
    procket:setsockopt(Socket, sol_socket(), ?SO_PASSCRED,
        <<0:4/native-unsigned-integer-unit:8>>);
setsockopt({unix,_}, _Socket, credrecv, _) ->
    ok.

sendmsg(Socket, Msg) ->
    sendmsg(Socket, Msg, 0).
sendmsg(Socket, {msghdr, Msg, _Res}, Flags) ->
    case procket:sendmsg(Socket, Msg, Flags) of
        {ok, _Bytes, _Msghdr} ->
            ok;
        Error ->
            Error
    end.

recvmsg(Socket, Msg) ->
    recvmsg(Socket, Msg, 0).
recvmsg(Socket, Msg, Flags) ->
    procket:recvmsg(Socket, Msg, Flags).
