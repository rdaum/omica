package web

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
server_run_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	web_server_run((^Web_Server)(data))
}

@(private)
start_server :: proc(t: ^testing.T, server: ^Web_Server, routes: ^Routes) -> ^thread.Thread {
	return start_server_with(t, server, routes_handle, routes)
}

@(private)
start_server_with :: proc(
	t: ^testing.T,
	server: ^Web_Server,
	handler: Web_Handler,
	user: rawptr,
) -> ^thread.Thread {
	// Cross-thread state: the acceptor appends to `server.connections` while
	// connection threads grow response builders from `server.allocator`, so
	// it must be the thread-safe heap, not the test's rollback allocator.
	ok, message := web_server_init(
		server,
		"127.0.0.1:0",
		handler,
		user,
		allocator = runtime.default_allocator(),
	)
	if !ok {
		testing.expectf(t, false, "server init failed: %s", message)
		return nil
	}
	return thread.create_and_start_with_data(server, server_run_worker)
}

@(private)
dial_server :: proc(t: ^testing.T, server: ^Web_Server) -> net.TCP_Socket {
	endpoint, endpoint_ok := web_server_endpoint(server)
	testing.expect(t, endpoint_ok)
	client, dial_err := net.dial_tcp(endpoint)
	testing.expect(t, dial_err == nil)
	_ = net.set_option(client, .Receive_Timeout, 200 * time.Millisecond)
	return client
}

@(private)
send_text :: proc(socket: net.TCP_Socket, text: string) {
	send_all(socket, transmute([]byte)text)
}

// Writes every byte; a single `send_tcp` may send only part of the buffer,
// which would leave the server waiting for the rest while the test waits for
// a response.
@(private)
send_all :: proc(socket: net.TCP_Socket, bytes: []byte) {
	sent := 0
	for sent < len(bytes) {
		count, send_err := net.send_tcp(socket, bytes[sent:])
		if send_err != .None || count <= 0 {
			return
		}
		sent += count
	}
}

// Reads exactly one HTTP response. Every response the server writes carries a
// `Content-Length`, so the read ends when the header block and the declared
// body have both arrived, regardless of how the bytes are chunked over the
// socket or how slowly the server thread is scheduled.
//
// The connection is keep-alive, so the peer does not close after the response
// and a receive timeout cannot mark the end. Waiting on Content-Length rather
// than on a timeout is what makes this deterministic: a receive timeout before
// any bytes (or before the body completes) just continues until the outer
// deadline, instead of returning a short or empty response.
@(private)
read_response :: proc(socket: net.TCP_Socket) -> []u8 {
	bytes: [dynamic]u8
	chunk: [4096]u8
	start := time.tick_now()
	header_end := -1
	expected := -1
	for time.tick_since(start) < 2 * time.Second {
		read, recv_err := net.recv_tcp(socket, chunk[:])
		if read > 0 {
			append(&bytes, ..chunk[:read])
			if header_end < 0 {
				if index := strings.index(string(bytes[:]), "\r\n\r\n"); index >= 0 {
					header_end = index + 4
					expected = content_length_of(string(bytes[:header_end])) + header_end
				}
			}
			if header_end >= 0 && expected >= 0 && len(bytes) >= expected {
				break
			}
			continue
		}
		if recv_err == .None && read == 0 {
			break
		}
		if recv_err == .Would_Block || recv_err == .Timeout || recv_err == .Interrupted {
			continue
		}
		break
	}
	return bytes[:]
}

// Parses the Content-Length from a header block, or -1 when absent.
@(private)
content_length_of :: proc(headers: string) -> int {
	lower := strings.to_lower(headers, context.temp_allocator)
	for line in strings.split_lines_iterator(&lower) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "content-length:") {
			continue
		}
		value := strings.trim_space(trimmed[len("content-length:"):])
		if parsed, ok := strconv.parse_int(value); ok {
			return parsed
		}
	}
	return -1
}

@(test)
test_server_healthz :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	text := string(response)
	testing.expectf(t, strings.contains(text, "HTTP/1.1 200 OK"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "Content-Length: 3"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "ok\n"), "response: %q", text)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

@(test)
test_server_keep_alive :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	net.set_option(client, .Receive_Timeout, 200 * time.Millisecond)
	first := read_response(client)
	defer delete(first)
	testing.expectf(t, strings.contains(string(first), "ok\n"), "first: %q", string(first))

	// The connection stays open for a second request.
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	second := read_response(client)
	defer delete(second)
	testing.expectf(t, strings.contains(string(second), "ok\n"), "second: %q", string(second))

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

@(test)
test_server_static_sync_client :: proc(t: ^testing.T) {
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_sync_client.js",
		directory,
		allocator = context.temp_allocator,
	)
	script := "export const marker = 1;\n"
	if write_err := os.write_entire_file(path, transmute([]byte)script); write_err != nil {
		testing.expect(t, false, "cannot write the static file")
		return
	}
	defer os.remove(path)

	routes: Routes
	if ok, message := routes_init(&routes, path); !ok {
		testing.expectf(t, false, "routes init failed: %s", message)
		return
	}
	defer routes_destroy(&routes)

	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /sync-client.js HTTP/1.1\r\nHost: a\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	text := string(response)
	testing.expectf(t, strings.contains(text, "HTTP/1.1 200 OK"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "text/javascript"), "response: %q", text)
	testing.expectf(t, strings.contains(text, script), "response: %q", text)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

@(test)
test_server_rejects_chunked :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(
		client,
		"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
	)
	response := read_response(client)
	defer delete(response)
	testing.expectf(
		t,
		strings.contains(string(response), "HTTP/1.1 400 Bad Request"),
		"response: %q",
		string(response),
	)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

@(test)
test_server_method_not_allowed :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "POST /healthz HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	testing.expectf(
		t,
		strings.contains(string(response), "HTTP/1.1 405 Method Not Allowed"),
		"response: %q",
		string(response),
	)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

// Completed connections must be reclaimed during operation, not only at
// shutdown.
@(test)
test_server_reaps_completed_connections :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	for _ in 0 ..< 3 {
		client := dial_server(t, &server)
		send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
		response := read_response(client)
		delete(response)
		net.close(client)
	}

	remaining := 0
	for _ in 0 ..< 100 {
		sync.mutex_lock(&server.lock)
		remaining = len(server.connections)
		sync.mutex_unlock(&server.lock)
		if remaining == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, remaining, 0)

	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)
}

@(private)
Arena_Probe :: struct {
	lock:     sync.Mutex,
	requests: int,
	arena:    [2]bool, // the handler's temp allocator was an arena
	empty:    [2]bool, // and nothing was allocated in it yet
}

@(private)
arena_probe_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	probe := (^Arena_Probe)(user)
	is_arena := context.temp_allocator.procedure == virtual.arena_allocator_proc
	empty := is_arena && (^virtual.Arena)(context.temp_allocator.data).total_used == 0
	// Scratch the next request must not see.
	_ = make([]u8, 1024, context.temp_allocator)
	sync.mutex_lock(&probe.lock)
	if probe.requests < len(probe.arena) {
		probe.arena[probe.requests] = is_arena
		probe.empty[probe.requests] = empty
	}
	probe.requests += 1
	sync.mutex_unlock(&probe.lock)
	response.status = 200
	response.body = transmute([]u8)string("ok\n")
}

// Every request on a keep-alive connection is handled in its own fresh arena.
@(test)
test_server_request_gets_fresh_temp_arena :: proc(t: ^testing.T) {
	probe: Arena_Probe
	server: Web_Server
	run_thread := start_server_with(t, &server, arena_probe_handler, &probe)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	for _ in 0 ..< 2 {
		send_text(client, "GET /probe HTTP/1.1\r\nHost: a\r\n\r\n")
		response := read_response(client)
		testing.expectf(t, strings.contains(string(response), "ok\n"), "response: %q", string(response))
		delete(response)
	}

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
	web_server_destroy(&server)

	testing.expect_value(t, probe.requests, 2)
	for i in 0 ..< 2 {
		testing.expectf(t, probe.arena[i], "request %d: temp allocator is not an arena", i)
		testing.expectf(t, probe.empty[i], "request %d: temp arena already held data", i)
	}
}
