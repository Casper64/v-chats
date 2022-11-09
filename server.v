module main

import net
import os
import rand
import json
import maps
import chats

const (
	server_port = 9001
)

// map_array mimics the javascripts `Array.map` function
pub fn map_array<T, R>(array []T, transform fn (elem T) R) []R {
	mut temp := []R{len: array.len}
	for val in array {
		temp << transform(val)
	}
	return temp
}

[heap]
struct SocketHandler {
mut:
	controller &SocketController
pub mut:
	sock         &net.TcpConn
	should_close bool

	user chats.User
}

// #region Commands implementation
// ===============================

// handle_command sends the correct reply to `command` to the client
pub fn (mut sh SocketHandler) handle_command(command string) {
	if command == 'ls rooms' {
		sh.reply_ls_rooms()
	} else if command.starts_with('get users room') {
		sh.reply_room_users(command)
	} else if command.starts_with('create room') {
		sh.create_room(command)
	} else if command.starts_with('join') {
		sh.join_room(command)
	}
	// All commands that need to send more information
	else if command_headers := json.decode(map[string]string, command) {
		if command_headers['Command-Type'] == 'dm' {
			sh.dm(command_headers)
		}
	}
}

// reply_ls_rooms sends the users rooms back
pub fn (mut sh SocketHandler) reply_ls_rooms() {
	rooms := maps.filter(sh.controller.rooms, fn [mut sh] (id string, room chats.Room) bool {
		return sh.user in room.users
	})

	// convert the rooms map to an array with only `chats.Room` values
	rooms_arr := maps.to_array(rooms, fn (id string, room chats.Room) chats.Room {
		return room
	})

	//  if the reply couldn't be send most likely the socket was closed unexpectedly so the socket is closed
	chats.reply_command(mut sh.sock, json.encode(rooms_arr)) or {
		eprintln('Reply failed???')
		sh.close()
	}
}

pub fn (mut sh SocketHandler) reply_room_users(command string) {
	room_id := command.replace('get users room', '').trim_space()

	if room_id in sh.controller.rooms {
		users := sh.controller.rooms[room_id].users
		chats.reply_command(mut sh.sock, json.encode(users)) or {
			eprintln('Reply failed???')
			sh.close()
		}
	} else {
		chats.reply_command(mut sh.sock, '[]') or {
			eprintln('Reply failed???')
			sh.close()
		}
	}
}

// dm sends a direct message to the receiving user
pub fn (mut sh SocketHandler) dm(headers map[string]string) {
	receiver := headers['To']
	for _, mut handler in sh.controller.handlers {
		// receiving user found
		if handler.user.id == receiver {
			message_headers := {
				'From':         sh.user.str()
				'Message':      headers['Message']
				'Message-Type': 'dm'
			}
			chats.send_message(mut handler.sock, message_headers) or { return }
			chats.reply_command(mut sh.sock, handler.user.str()) or {
				eprintln('Reply failed???')
				sh.close()
			}
			return
		}
	}
	// no receiver found :(
	chats.reply_command(mut sh.sock, '') or {
		eprintln('Reply failed???')
		sh.close()
	}
}

pub fn (mut sh SocketHandler) create_room(command string) {
	room_name := command.split(' ')[2..].join(' ')

	room_id := sh.controller.create_room(room_name)
	sh.controller.rooms[room_id].users << sh.user

	chats.reply_command(mut sh.sock, json.encode(sh.controller.rooms[room_id])) or {
		eprintln('Reply failed???')
		sh.close()
	}
}

// handle_message distributes an incoming message from one user to other users in the same room
pub fn (mut sh SocketHandler) handle_message(data string) {
	message_headers := json.decode(map[string]string, data) or {
		eprintln('Wrong formed message header! $err\n$data')
		return
	}

	// List of all users in the room except the sender
	mut users := sh.controller.rooms[message_headers['Room']].users.clone()
	users = users.filter(it.id != message_headers['From'])
	user_ids := map_array(users, fn (u chats.User) string {
		return u.id
	})

	// loop over all sockets connected to the server and check if their user id is in the room
	for _, mut handler in sh.controller.handlers {
		if handler.user.id != '' && handler.user.id in user_ids {
			chats.send_message(mut handler.sock, message_headers) or { continue }
		}
	}
}

pub fn (mut sh SocketHandler) join_room(command string) {
	room_id := command.split(' ')[1]

	if room_id in sh.controller.rooms {
		sh.controller.rooms[room_id].users << sh.user
		chats.reply_command(mut sh.sock, 'suc6') or {
			eprintln('Reply failed???')
			sh.close()
		}
	} else {
		chats.reply_command(mut sh.sock, '') or {
			eprintln('Reply failed???')
			sh.close()
		}
	}
}

// #endregion
// #region Core fucntionality
// ==========================

// close closes the socket and removes it from the socket controller
pub fn (mut sh SocketHandler) close() {
	println('Closing connection with $sh.sock.sock.handle')
	sh.controller.remove_socket(mut sh)
	sh.sock.close() or { panic(err) }
}

// handle_connection is the entry point that handles all incoming messags from the client after the connection is made
pub fn (mut sh SocketHandler) handle_connection() {
	defer {
		sh.close()
	}

	client_addr := sh.sock.peer_addr() or { return }
	println('New client: $sh.sock.sock.handle ($client_addr)')

	// 1. obtain username from client and send back the users id
	username := chats.receive_str(mut sh.sock) or { return }

	user_id := rand.hex(8)
	sh.user = chats.User{
		username: username
		id: user_id
	}
	println('Created user $sh.user')

	chats.send_string(mut sh.sock, user_id) or { panic(err) }

	// 2. Add user to global chat
	sh.controller.rooms['global-chat'].add_user(sh.user)

	// 3. Handle messages from the client
	for {
		message := chats.receive(mut sh.sock) or { return }

		// end connection message
		if message['Content-Type'] == 'string' && message['Content'] == chats.end_string {
			println('$sh.user wants to close the connection')
			return
		} else if message['Content-Type'] == 'command' {
			sh.handle_command(message['Content'])
		} else if message['Content-Type'] == 'message' {
			sh.handle_message(message['Content'])
		} else if message['Content-Type'] == 'keep-alive' {
			continue
		}

		// debugging
		// println('$sh.user $message')
	}
}

struct SocketController {
pub mut:
	handlers map[int]&SocketHandler
	rooms    map[string]chats.Room
}

// add_socket adds the `socket_handler` to `handlers` with its key being the TcpConn sockets handler
pub fn (mut sc SocketController) add_socket(mut socket_handler SocketHandler) {
	sc.handlers[socket_handler.sock.sock.handle] = socket_handler
}

// remove_socket removes `socket_handler` from all rooms and from the controller itself.
// remove_socket doesn't close the socket and should be called before the socket is closed for future implementation reasons!
pub fn (mut sc SocketController) remove_socket(mut socket_handler SocketHandler) {
	for room_id, mut room in sc.rooms {
		room.users = room.users.filter(it.id != socket_handler.user.id)
		// cleanup, but keep the global chat :)
		if room_id != 'global-chat' && room.users.len == 0 {
			sc.rooms.delete(room_id)
		}
	}
	sc.handlers.delete(socket_handler.sock.sock.handle)
}

pub fn (mut sc SocketController) create_room(name string) string {
	room_id := rand.hex(8)
	sc.rooms[room_id] = chats.Room{
		id: room_id
		name: name
		users: []
	}
	return room_id
}

// accept_connection wait for an incoming connection
fn accept_connection(shared controller SocketController, mut server net.TcpListener, c chan &SocketHandler) {
	mut socket := server.accept() or { panic(err) }

	// set socket options
	socket.sock.set_option_bool(.reuse_addr, true) or { panic(err) }
	socket.sock.set_option_bool(.keep_alive, true) or { panic(err) }

	// create a handler for the `socket` and push the handler into channel `c`
	mut handler := &SocketHandler{
		sock: socket
		controller: controller
	}
	c <- handler

	handler.handle_connection()
}

// handle_clients accepts a connection in another thread and retrieves the created `SocketHandler` and adds it to `controller`
fn handle_clients(mut server net.TcpListener, shared controller SocketController) {
	for {
		c := chan &SocketHandler{}
		go accept_connection(shared controller, mut server, c)
		// wait for the thread to push the created `SocketHandler` instance to the channel
		mut handler := <-c

		lock controller {
			controller.add_socket(mut handler)
		}
	}
}

// #endregion
// #region Start script
// ====================

fn main() {
	// only listen on ipv4 on the localhost
	// else do .ip(6) with ':server_port' to listen outside of the localhost
	mut server := net.listen_tcp(.ip, 'localhost:$server_port')!
	laddr := server.addr()!
	println('Listening on $laddr')

	// the controller needs to be accessed by different threads that's why the type is `shared`
	shared controller := &SocketController{}
	// add the default room 'global-chat' which is available to all users
	lock controller {
		controller.rooms['global-chat'] = chats.Room{
			id: 'global-chat'
			name: 'Global chat'
			users: []
		}
	}
	// accept all inocming connections in a different thread
	go handle_clients(mut server, shared controller)

	// handle all input from until the application is stopped by the user
	for {
		input := os.get_line()

		if input == 'stop' {
			println('closing socket connections')

			lock controller {
				for handle, mut handler in controller.handlers {
					println('Closing connection with $handle')
					// shouldn't panic because the other sockets also need to be closed
					chats.send_string(mut handler.sock, chats.end_string) or { eprintln(err) }
					handler.sock.close() or { eprintln(err) }
				}
			}

			return
		}
		// debugging
		println('server: $input')
	}
}

// #endregion
