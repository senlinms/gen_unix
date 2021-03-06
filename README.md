gen\_unix is an Erlang interface to Unix sockets. The main purpose of
gen\_unix is to allow access to socket ancillary data required for fd
and credential passing.

WARNING: gen\_unix is still under development and going through a lot
of change.

Examples
========

* File descriptor passing

  Open 2 shell prompts and start an Erlang VM in each:

        # VM 1
        $ rebar shell
        1> {ok, Ref} = gen_unix:start().
        {ok,<0.35.0>}

        2> {ok, Listen} = gen_unix:listen(Ref, "/tmp/test").
        {ok,8}

        # VM 2
        $ sudo rebar shell
        1> {ok, Ref} = gen_unix:start().
        {ok,<0.35.0>}

        2> {ok, Socket} = gen_unix:connect(Ref, "/tmp/test").
        {ok,7}

        2> {ok, FD1} = procket:socket(inet,raw,icmp).
        {ok,8}

        3> {ok, FD2} = procket:socket(inet6,raw,icmp6).
        {ok,9}

        4> {ok, Msg} = unixsock:msg({fdsend, [FD1,FD2]}).
        {ok,{msghdr,<<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,160,114,0,
                      232,20,127,0,0,1,...>>,
                      [{msg_iov,<<>>},{msg_control,<<>>},{iov,[<<>>]}]}}

        5> gen_unix:sendmsg(Ref, Socket, Msg).
        ok

        # Open another shell and send a few ping's

        # Back in VM 1
        2> {ok, Socket} = gen_unix:accept(Ref, Listen).
        {ok,9}

        3> {ok, Msg} = unixsock:msg({fdrecv, 2}).
        {ok,{msghdr,<<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,160,114,0,
                      128,198,127,0,0,1,...>>,
                      [{msg_iov,<<>>},{msg_control,<<>>},{iov,[<<>>]}]}}

        4> gen_unix:recvmsg(Ref, Socket, Msg).
        {ok,1}

        % [8,9]
        5> {ok, [FD1, FD2]} = unixsock:msg(Msg).
        {ok,"\t\n"}

        5> procket:read(FD1, 1024).
        {ok,<<69,0,0,84,236,114,0,0,56,1,38,238,173,194,43,69,
              192,168,213,152,0,0,98,95,21,173,0,...>>}

* Credential passing

        # VM 1
        $ rebar shell
        1> {ok, Ref} = gen_unix:start().
        {ok,<0.35.0>}

        2> {ok, Listen} = gen_unix:listen(Ref, "/tmp/test").
        {ok,8}

        # VM 2
        $ rebar shell
        1> {ok, Ref} = gen_unix:start().
        {ok,<0.35.0>}

        2> {ok, Socket} = gen_unix:connect(Ref, "/tmp/test").
        {ok,7}

        2> {ok, Msg} = unixsock:msg(credsend).
        {ok,{msghdr,<<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,115,0,232,
                      20,127,0,0,1,...>>,
                      [{msg_iov,<<>>},{iov,[<<>>]}]}}

        3> gen_unix:sendmsg(Ref, Socket, Msg).
        ok

        # Back in VM 1
        2> {ok, Socket} = gen_unix:accept(Ref, Listen).
        {ok,9}

        3> {ok, Msg} = unixsock:msg(credrecv).
        {ok,{msghdr,<<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,115,0,128,
                      198,127,0,0,1,...>>,
                      [{msg_iov,<<>>},{msg_control,<<>>},{iov,[<<>>]}]}}

        4> unixsock:setsockopt(Socket, {credrecv, open}).
        ok

        5> gen_unix:recvmsg(Ref, Socket, Msg).
        {ok,1}

        6> unixsock:msg(Msg).
        {ok, [{pid,12866},{uid,1000},{gid,1000}]}

        7> unixsock:setsockopt(Socket, {credrecv, close}).
        ok
