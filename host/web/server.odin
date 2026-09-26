// A small HTTP/1.1 server: one acceptor thread plus one thread per connection.
//
// Connection threads parse requests, call the handler, and write responses.
// They never touch the kernel. The handler is expected to hand work to tasks
// and wait for results off the connection thread.
package web

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Fills `response` for one request. The response body must stay alive until
// the response is written.
Web_Handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response)

// Takes over a connection to write a streaming response. Returns true when the
// request was handled; the server closes the connection when the handler
// returns.
Web_Stream_Handler :: proc(user: rawptr, request: ^Http_Request, socket: net.TCP_Socket) -> bool

DEFAULT_BACKLOG :: 512
RECV_BUFFER_SIZE :: 16 * 1024

Web_Connection :: struct {
	server: ^Web_Server,
	socket: net.TCP_Socket,
	thread: ^thread.Thread,
	// Guarded by `server.lock`. Set before the socket closes.
	done:   bool,
}

Web_Server :: struct {
	listener:       net.TCP_Socket,
	handler:        Web_Handler,
	stream_handler: Web_Stream_Handler,
	user:           rawptr,
	limits:      Http_Limits,
	lock:        sync.Mutex,
	stopping:    bool,
	connections: [dynamic]^Web_Connection,
	allocator:   mem.Allocator,
}

// Binds and listens. Returns false with a message on failure.
web_server_init :: proc(
	server: ^Web_Server,
	bind: string,
	handler: Web_Handler,
	user: rawptr,
	limits := DEFAULT_HTTP_LIMITS,
	allocator := context.allocator,
) -> (
	ok: bool,
	message: string,
) {
	server.handler = handler
	server.user = user
	server.limits = limits
	server.allocator = allocator
	server.connections = make([dynamic]^Web_Connection, allocator)

	endpoint, parsed := net.parse_endpoint(bind)
	if !parsed {
		return false, "invalid bind address"
	}
	listener, listen_err := net.listen_tcp(endpoint, DEFAULT_BACKLOG)
	if listen_err != nil {
		return false, "cannot listen on the bind address"
	}
	// Non-blocking accept lets `web_server_stop` wake the acceptor by
	// shutting the listener down. The listener is closed by
	// `web_server_destroy`, after the acceptor has been joined: closing it
	// in `web_server_stop` would free the fd while the acceptor may still
	// call accept, and a reused fd could steal another server's client.
	_ = net.set_blocking(listener, false)
	server.listener = listener
	return true, ""
}

// Registers a handler that gets first chance at each request and can write a
// streaming response.
web_server_set_stream_handler :: proc(server: ^Web_Server, handler: Web_Stream_Handler) {
	server.stream_handler = handler
}

// The actual bound endpoint. Useful when the bind port is zero.
web_server_endpoint :: proc(server: ^Web_Server) -> (net.Endpoint, bool) {
	endpoint, err := net.bound_endpoint(server.listener)
	return endpoint, err == .None
}

// Reaps connection threads that have finished. Called by the acceptor so a
// long-running server keeps only live connections. Joining happens after the
// array is compacted under the lock, so it cannot deadlock a worker.
@(private)
web_server_reap_connections :: proc(server: ^Web_Server) {
	done: [dynamic]^Web_Connection
	done = make([dynamic]^Web_Connection, context.allocator)
	sync.mutex_lock(&server.lock)
	write := 0
	for connection in server.connections {
		if connection.done {
			append(&done, connection)
			continue
		}
		server.connections[write] = connection
		write += 1
	}
	resize(&server.connections, write)
	sync.mutex_unlock(&server.lock)

	for connection in done {
		if connection.thread != nil {
			thread.join(connection.thread)
			thread.destroy(connection.thread)
		}
		free(connection, server.allocator)
	}
	delete(done)
}

// Accepts connections until `web_server_stop` shuts the listener down. Each
// connection runs on its own thread.
web_server_run :: proc(server: ^Web_Server) {
	for {
		web_server_reap_connections(server)
		client, _, accept_err := net.accept_tcp(server.listener)
		if accept_err != .None {
			sync.mutex_lock(&server.lock)
			stopping := server.stopping
			sync.mutex_unlock(&server.lock)
			if stopping {
				return
			}
			if accept_err == .Would_Block {
				time.sleep(1 * time.Millisecond)
			}
			continue
		}
		// Accepted sockets inherit the listener's non-blocking flag on
		// BSD/macOS (but not Linux). Restore blocking mode so keep-alive
		// reads wait for the next request and SO_RCVTIMEO bounds the SSE
		// path; the acceptor stays non-blocking to poll for shutdown.
		_ = net.set_blocking(client, true)
		net.set_option(client, .TCP_Nodelay, true)
		connection := new(Web_Connection, server.allocator)
		connection.server = server
		connection.socket = client
		connection.thread = thread.create_and_start_with_data(
			connection,
			web_connection_worker,
		)
		if connection.thread == nil {
			net.close(client)
			free(connection, server.allocator)
			continue
		}
		sync.mutex_lock(&server.lock)
		if server.stopping {
			// Shutdown won the race after the worker started; drain this
			// connection here so it is not orphaned.
			sync.mutex_unlock(&server.lock)
			net.shutdown(client, .Both)
			thread.join(connection.thread)
			thread.destroy(connection.thread)
			free(connection, server.allocator)
			return
		}
		append(&server.connections, connection)
		sync.mutex_unlock(&server.lock)
	}
}

// Stops the acceptor, unblocks active connections, and joins every connection
// thread. Must be called once after `web_server_run` is running or has failed.
//
// The listener is shut down, not closed: the acceptor may still be inside
// `accept_tcp`, and closing the fd would let an unrelated socket reuse the
// number, so the acceptor could steal another server's client and shut it
// down. Call `web_server_destroy` after the acceptor has been joined to
// release the listener.
web_server_stop :: proc(server: ^Web_Server) {
	sync.mutex_lock(&server.lock)
	server.stopping = true
	sync.mutex_unlock(&server.lock)
	net.shutdown(server.listener, .Both)

	// Take ownership of the connection set under the lock, then unblock and
	// join outside it. This prevents concurrent traversal/mutation.
	sync.mutex_lock(&server.lock)
	drained := server.connections
	server.connections = make([dynamic]^Web_Connection, server.allocator)
	for connection in drained {
		if !connection.done {
			net.shutdown(connection.socket, .Both)
		}
	}
	sync.mutex_unlock(&server.lock)

	for connection in drained {
		if connection.thread != nil {
			thread.join(connection.thread)
			thread.destroy(connection.thread)
		}
		free(connection, server.allocator)
	}
	delete(drained)
}

// Releases the listener. Call once, after `web_server_stop` and after the
// thread running `web_server_run` has been joined, so no accept can be
// in flight when the fd is closed and reused.
web_server_destroy :: proc(server: ^Web_Server) {
	net.close(server.listener)
	delete(server.connections)
}

@(private)
web_connection_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	connection := (^Web_Connection)(data)
	web_connection_serve(connection)
	sync.mutex_lock(&connection.server.lock)
	connection.done = true
	net.close(connection.socket)
	sync.mutex_unlock(&connection.server.lock)
}

// Serves requests on one connection until it closes or faults.
web_connection_serve :: proc(connection: ^Web_Connection) {
	// One scratch arena per connection, installed here so it covers the
	// whole loop, and emptied after every request.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	server := connection.server
	parser: Http_Parser
	http_parser_init(&parser, server.limits)
	defer http_parser_destroy(&parser)

	recv_buffer: [RECV_BUFFER_SIZE]u8
	response_builder: strings.Builder
	strings.builder_init(&response_builder, server.allocator)
	defer strings.builder_destroy(&response_builder)

	for {
		request, state, parse_error := http_parser_next(&parser)
		switch state {
		case .Ready:
			keep_alive := web_connection_respond(connection, &request, &response_builder)
			http_parser_consume(&parser, parser.last_total)
			strings.builder_reset(&response_builder)
			free_all(context.temp_allocator)
			if !keep_alive {
				return
			}
		case .Incomplete:
			read, recv_err := net.recv_tcp(connection.socket, recv_buffer[:])
			if read <= 0 || recv_err != .None {
				return
			}
			http_parser_push(&parser, recv_buffer[:read])
		case .Error:
			write_parse_error(connection, parse_error)
			return
		}
	}
}

// Handles one request. `context.temp_allocator` is emptied after the request,
// so anything kept longer must be copied into its owner's allocator. Reports
// whether the connection stays open for another request.
@(private)
web_connection_respond :: proc(
	connection: ^Web_Connection,
	request: ^Http_Request,
	builder: ^strings.Builder,
) -> bool {
	server := connection.server
	if server.stream_handler != nil && server.stream_handler(server.user, request, connection.socket) {
		return false
	}
	response := Http_Response {
		close = request.close,
	}
	server.handler(server.user, request, &response)
	http_encode_response(&response, builder)
	sent := web_send_all(connection.socket, transmute([]byte)strings.to_string(builder^))
	return sent && !request.close
}

@(private)
write_parse_error :: proc(connection: ^Web_Connection, parse_error: Http_Parse_Error) {
	builder: strings.Builder
	strings.builder_init(&builder, connection.server.allocator)
	defer strings.builder_destroy(&builder)

	response := Http_Response {
		status = parse_error.status,
		close  = true,
	}
	http_response_text(&response, parse_error.status, "text/plain", parse_error.message)
	http_encode_response(&response, &builder)
	_ = web_send_all(connection.socket, transmute([]byte)strings.to_string(builder))
}

// Writes every byte or reports failure.
@(private)
web_send_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	written := 0
	for written < len(bytes) {
		count, send_err := net.send_tcp(socket, bytes[written:])
		if count <= 0 || send_err != .None {
			return false
		}
		written += count
	}
	return true
}
