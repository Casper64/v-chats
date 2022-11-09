module chats

import net
import json

pub const (
	end_string  = 'EXIT!'
	header_size = 128
)

pub struct User {
pub:
	username string
	id       string
}

pub fn (u User) str() string {
	return '$u.username:$u.id'
}

pub struct Room {
pub mut:
	users []User
	id    string
	name  string
}

pub fn (mut r Room) add_user(user User) {
	r.users << user
}

pub fn (mut r Room) remove_user(user User) {
	r.users.delete(r.users.index(user))
}

pub fn (r Room) str() string {
	return 'Room {r.name}:{r.id}'
}

// send writes `message` as a string to the socket `conn` and add the `message_type` as 'Content-Type' value in the header
pub fn send(mut conn net.TcpConn, message string, message_type string) ! {
	message_headers := {
		'Content-Type': message_type
		'Content':      message
	}
	bytes_str := json.encode(message_headers).bytes()

	mut headers := {
		'Content-Length': bytes_str.len.str()
	}
	mut headers_str := json.encode(headers).bytes()

	// pad headers_str to become header_size
	excess_length := chats.header_size - headers_str.len
	for _ in 0 .. excess_length {
		headers_str << ` `
	}

	conn.write(headers_str)!
	conn.write(bytes_str)!
}

// send_string sets the 'Content-Type' of the header to 'string'
pub fn send_string(mut conn net.TcpConn, message string) ! {
	send(mut conn, message, 'string')!
}

// send_message sets the 'Content-Type' of the header to 'message' and encodes the `message_headers` with json
pub fn send_message(mut conn net.TcpConn, message_headers map[string]string) ! {
	send(mut conn, json.encode(message_headers), 'message')!
}

// send_command sets the 'Content-Type' of the header to 'command'
pub fn send_command(mut conn net.TcpConn, command string) ! {
	send(mut conn, command, 'command')!
}

// reply_command sets the 'Content-Type' of the header to 'command-reply'
pub fn reply_command(mut conn net.TcpConn, reply string) ! {
	send(mut conn, reply, 'command-reply')!
}

// receive waits for data to and returns the resulting headers
pub fn receive(mut conn net.TcpConn) !map[string]string {
	mut header_buf := []u8{len: chats.header_size}

	conn.read(mut header_buf)!
	headers := json.decode(map[string]string, header_buf.bytestr().trim_space())!

	mut message_buf := []u8{len: headers['Content-Length'].int()}
	conn.read(mut message_buf)!

	return json.decode(map[string]string, message_buf.bytestr())!
}

// receive_str waits for data and only returns the 'Content' field from resulting headers
pub fn receive_str(mut conn net.TcpConn) !string {
	result := receive(mut conn)!
	return result['Content']
}
