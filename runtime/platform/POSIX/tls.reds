Red/System [
	Title:   "TLS support on POSIX"
	Author:  "Xie Qingtian"
	File:	 %tls.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2014-2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

tls: context [

	server-ctx: as int-ptr! 0
	client-ctx: as int-ptr! 0

	create-private-key: func [
		return: [int-ptr!]
		/local
			bn	[int-ptr!]
			rsa [int-ptr!]
			prv [int-ptr!]
	][
		bn: BN_new
		BN_set_word bn 17
		rsa: RSA_new
		RSA_generate_key_ex rsa 2048 bn null
		prv: EVP_PKEY_new
		EVP_PKEY_set1_RSA prv rsa
		RSA_free rsa
		BN_free bn
		return prv
	]

	create-certificate: func [
		pkey	[int-ptr!]		;-- private key
		return: [int-ptr!]
		/local
			cert	[int-ptr!]
			name	[int-ptr!]
	][
		cert: X509_new
		ASN1_INTEGER_set X509_get_serialNumber cert 1
		X509_time_adj_ex X509_getm_notBefore cert 0 0 0
		X509_time_adj_ex X509_getm_notAfter cert 365 0 0
		X509_set_pubkey cert pkey
		
		name: X509_get_subject_name cert
		X509_NAME_add_entry_by_txt name "C" 1001h "CA" -1 -1 0
		X509_NAME_add_entry_by_txt name "O" 1001h "Red Language" -1 -1 0
		X509_NAME_add_entry_by_txt name "CN" 1001h "localhost" -1 -1 0
		X509_set_issuer_name cert name

		X509_sign cert pkey EVP_sha1
		cert
	]

	load-cert: func [
		ctx			[int-ptr!]
		cert		[red-string!]
		chain?		[logic!]
		return:		[integer!]
		/local
			len		[integer!]
			str		[c-string!]
			bio		[int-ptr!]
			x509	[int-ptr!]
	][
		len: -1
		str: unicode/to-utf8 cert :len

		bio: BIO_new_mem_buf str len
		if null? bio [return 1]
		x509: PEM_read_bio_X509 bio null null null
		BIO_free bio
		if null? x509 [
			return 2
		]
		either chain? [
			if 1 <> SSL_CTX_ctrl ctx SSL_CTRL_CHAIN_CERT 1 x509 [
				X509_free x509
				return 3
			]
		][
			if 1 <> SSL_CTX_use_certificate ctx x509 [
				X509_free x509
				return 4
			]
		]

		X509_free x509
		0
	]

	link-private-key: func [
		ctx			[int-ptr!]
		key			[red-string!]
		pwd			[red-string!]
		return:		[integer!]
		/local
			len		[integer!]
			str		[c-string!]
			bio		[int-ptr!]
			pkey	[int-ptr!]
	][
		len: -1
		str: unicode/to-utf8 key :len

		bio: BIO_new_mem_buf str len
		if null? bio [return 1]
		pkey: PEM_read_bio_PrivateKey bio null null null
		BIO_free bio
		if null? pkey [
			return 2
		]
		if 1 <> SSL_CTX_use_PrivateKey ctx pkey [
			EVP_PKEY_free pkey
			return 3
		]
		if 1 <> SSL_CTX_check_private_key ctx [
			EVP_PKEY_free pkey
			return 4
		]
		EVP_PKEY_free pkey
		0
	]

	store-identity: func [
		data		[tls-data!]
		ssl_ctx		[int-ptr!]
		return:		[logic!]
		/local
			values	[red-value!]
			extra	[red-block!]
			certs	[red-block!]
			head	[red-string!]
			tail	[red-string!]
			first?	[logic!]
			key		[red-string!]
			pwd		[red-string!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return false]
		certs: as red-block! block/select-word extra word/load "certs" no
		if TYPE_OF(certs) <> TYPE_BLOCK [return false]
		head: as red-string! block/rs-head certs
		tail: as red-string! block/rs-tail certs
		first?: yes
		while [head < tail][
			if TYPE_OF(head) = TYPE_STRING [
				if 0 <> load-cert ssl_ctx head not first? [
					IODebug("load cert failed!!!")
					return false
				]
				if first? [
					first?: no
					key: as red-string! block/select-word extra word/load "key" no
					pwd: as red-string! block/select-word extra word/load "password" no
					if 0 <> link-private-key ssl_ctx key pwd [
						IODebug("link key failed!!!")
						return false
					]
				]
			]
			head: head + 1
		]
		not first?
	]

	get-domain: func [
		data		[tls-data!]
		return:		[c-string!]
		/local
			values	[red-value!]
			extra	[red-block!]
			domain	[red-string!]
			len		[integer!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return null]
		domain: as red-string! block/select-word extra word/load "domain" no
		if TYPE_OF(domain) <> TYPE_STRING [return null]
		len: -1
		unicode/to-utf8 domain :len
	]

	create: func [
		td		[tls-data!]
		client? [logic!]
		/local
			ctx		[int-ptr!]
			ssl		[int-ptr!]
			fd		[integer!]
			err		[integer!]
			pk		[int-ptr!]
			cert	[int-ptr!]
	][
		IODebug("tls/create")
		ERR_clear_error
		if null? td/ssl [
			either client? [
				if null? client-ctx [
					client-ctx: SSL_CTX_new TLS_client_method
					store-identity td client-ctx
					SSL_CTX_set_mode(client-ctx 5)
				]
				ctx: client-ctx
			][
				if null? server-ctx [
					server-ctx: SSL_CTX_new TLS_server_method
					unless store-identity td server-ctx [ ;-- create an internal cert if no cert specified
						;-- bitbegin note: default cert should be provided by upper
						pk: create-private-key
						cert: create-certificate pk
						SSL_CTX_use_certificate server-ctx cert
						SSL_CTX_use_PrivateKey server-ctx pk
					]
					SSL_CTX_set_mode(server-ctx 5)
					SSL_CTX_set_cipher_list server-ctx "ECDHE+AES:@STRENGTH:+AES256"
				]
				ctx: server-ctx
			]

			ssl: SSL_new ctx
			td/ssl: ssl
			if null? ssl [probe "SSL_new failed" exit]

			fd: as-integer td/device
			if zero? SSL_set_fd ssl fd [
				probe "SSL_set_fd error"
			]
			either client? [
				SSL_ctrl ssl SSL_CTRL_SET_TLSEXT_HOSTNAME TLSEXT_NAMETYPE_host_name as int-ptr! get-domain td
				SSL_set_connect_state ssl
			][
				SSL_set_accept_state ssl
			]
		]
	]

	update-td: func [
		td	[tls-data!]
		evt [integer!]
		/local
			state [integer!]
	][
		state: td/state
		either state and IO_STATE_RW = 0 [
			iocp/add td/io-port as-integer td/device evt or EPOLLET as iocp-data! td
		][
			if state <> evt [iocp/modify td/io-port as-integer td/device evt or EPOLLET as iocp-data! td]
		]
		probe ["update-td: " state " " evt]
		td/state: evt
	]

	negotiate: func [
		td		[tls-data!]
		return: [integer!]		;-- 0: continue, 1: success, -1: error
		/local
			ssl [int-ptr!]
			ret [integer!]
			p	[red-object!]
	][
		IODebug("tls/negotiate")
		ssl: td/ssl
		ret: SSL_do_handshake ssl
		either ret = 1 [td/state: td/state or IO_STATE_TLS_DONE 1][
			ret: SSL_get_error ssl ret
			probe ["errno: " errno/value]
			switch ret [
				SSL_ERROR_WANT_READ [
					update-td td EPOLLIN
				]
				SSL_ERROR_WANT_WRITE [
					update-td td EPOLLOUT
				]
				default [
					check-errors ret
					ERR_clear_error
					either td/state and IO_STATE_CLIENT <> 0 [	;-- tls client
						td/event: IO_EVT_CLOSE
						td/state: td/state or IO_STATE_ERROR
					][
						td/event: IO_EVT_ERROR
						SSL_free ssl
						if td/state <> 0 [
							iocp/remove td/io-port as-integer td/device td/state as iocp-data! td
						]
						socket/close as-integer td/device
						td/device: IO_INVALID_DEVICE
						td/io-port/n-ports: td/io-port/n-ports - 1
					]
					return -1
				]
			]
			0
		]
	]

	check-errors: func [code [integer!]][
		IODebug(["check errors" code])
		until [				;-- clear the error stack in openssl
			code: ERR_get_error
			if code <> 0 [ERR_error_string code null]
			zero? code
		]
		IODebug("check errors finish")
	]

	free-handle: func [
		td		[tls-data!]
		/local
			ssl [int-ptr!]
			ret state sock [integer!]
	][
		ssl: td/ssl
		IODebug(["native tls free handle" td/state td/device])
		if all [ssl <> null td/state and IO_STATE_ERROR = 0][
			ret: SSL_get_shutdown ssl
			?? ret
			if ret = 0 [	;-- no shutdown yet
				ERR_clear_error
				ret: SSL_shutdown ssl	;@@ this API will crash silently if fd was closed
				?? ret
				if ret < 0 [
					ret: SSL_get_error ssl ret
					check-errors -1
					if ret = SSL_ERROR_WANT_WRITE [
						state: td/state
						sock: as-integer td/device
						case [
							state and IO_STATE_RW = 0 [
								td/state: state or IO_STATE_PENDING_WRITE
								iocp/add td/io-port sock EPOLLOUT or EPOLLET as iocp-data! td
							]
							state and EPOLLOUT = 0 [
								td/state: state or IO_STATE_PENDING_WRITE
								iocp/modify td/io-port sock EPOLLIN or EPOLLOUT or EPOLLET as iocp-data! td
							]
							true [td/state: state or IO_STATE_WRITING]
						]
						td/state: IO_STATE_CLOSING or td/state
						exit
					]
				]
			]
		]

		;-- the close_notify was sent
		;-- we don't care about the reply from the peer
		if ssl <> null [SSL_free ssl]
		socket/close as-integer td/device
		td/device: IO_INVALID_DEVICE
		IODebug("native tls free handle done")
	]
]