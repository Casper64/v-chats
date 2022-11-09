module main

import net
import os
import json
import time
import chats

struct ClientController {
	user chats.User
mut:
	sock &net.TcpConn
	// this callback is called when the result of a command is received
	command_callback fn (data string)
	// wether a thread is processing a command
	processing_command bool

	rooms []chats.Room
	// index is current_room - 1
	current_room_index int

	should_stop bool
}

// #region Commands implementation
// ===============================

// current_room returns the current room the user has joined else current_rooms returns an option
pub fn (cc ClientController) current_room() ?chats.Room {
	// make sure the user has joined a room
	if cc.current_room_index == 0 || cc.current_room_index > cc.rooms.len {
		return none
	} else {
		return cc.rooms[cc.current_room_index - 1]
	}
}

// ls_rooms requests the which rooms the current can join from the server and displays them to the user
pub fn (mut cc ClientController) ls_rooms() {
	chats.send_command(mut cc.sock, 'ls rooms') or {
		println(err)
		return
	}

	cc.command_callback = fn [mut cc] (data string) {
		mut rooms := json.decode([]chats.Room, data) or { panic(err) }
		cc.rooms = rooms

		for i, room in rooms {
			// We need to add 1 to the room index, because `string.int()` returns 0 if it can't find a valid digit
			println('Room {i + 1}: "{room.name}" with id {room.id}')
		}

		cc.processing_command = false
	}
}

// join parses the room number from `command` and if the room is valid let the user join the room
pub fn (mut cc ClientController) join(command string) {
	defer {
		// reset `processing_command` to indicate that the command has been procesed when the function is done
		cc.processing_command = false
	}

	room := command.replace(':join', '').trim_space().int()
	// if `room == 0` then the result is not an int or 0. That is why the `current_room_index` starts at 1 and not 0
	if room == 0 {
		eprintln('Invalid argument.\nUsage: ":join \$room_index". For a list of available rooms execute ":ls rooms"')
		return
	} else if room > cc.rooms.len {
		println('Room "$room" doesn\'t exist!\n')
		return
	}

	// the entered room is valid
	println('Joined room $room')
	cc.current_room_index = room
}

// show_current_room displays the room the user is currently joined in and notifies the user if no room is joined
pub fn (cc ClientController) show_current_room() {
	if room := cc.current_room() {
		println('Room {cc.current_room_index}: "{room.name}"" with id {room.id}')
	} else {
		println('You are not in a room right now!')
	}
}

// leave_room leaves the currently room and else notifies the user that no was joined
pub fn (mut cc ClientController) leave_room() {
	if _ := cc.current_room() {
		println('Leaving room...')
		cc.current_room_index = 0
	} else {
		println('You are not in a room right now!')
	}
}

// dm sends a direct message to the user provided in the command string
pub fn (mut cc ClientController) dm(command string) {
	splitted := command.split(' ')

	if splitted.len == 1 {
		println('You must provide a user id an an message!\nUsage:":dm \$user \$message" send a direcet message. "\$user" can be a user id or their name in your contacts')
		cc.processing_command = false
		return
	} else if splitted.len == 2 {
		println('You must provide a message! Usage:\n":dm \$user \$message" send a direcet message. "\$user" can be a user id or their name in your contacts')
		cc.processing_command = false
		return
	}

	// build dm headers
	user_id := splitted[1]
	message := splitted[2..].join(' ')

	dm_headers := {
		'Command-Type': 'dm'
		'From':         cc.user.str()
		'To':           user_id
		'Message':      message
	}
	chats.send_command(mut cc.sock, json.encode(dm_headers)) or {
		eprintln(err)
		return
	}

	// provide feedback to the user if no user with the user id exists
	cc.command_callback = fn [mut cc, user_id] (data string) {
		defer {
			cc.processing_command = false
		}
		if data == '' {
			println('User with id="{user_id}" does not exist!')
		}
	}
}

// get_all_room_users requests all users that can access the room
pub fn (mut cc ClientController) get_all_room_users() {
	if room := cc.current_room() {
		chats.send_command(mut cc.sock, 'get users room {room.id}') or {
			eprintln(err)
			return
		}

		cc.command_callback = fn [mut cc, room] (data string) {
			defer {
				cc.processing_command = false
			}

			room_users := json.decode([]chats.User, data) or { return }
			println('Users of the room "{room.name}":')
			for user in room_users {
				println('\t{user.username}: {user.id}')
			}
		}
	}
}

// show_room_id displays the current room id to the user if the user has joined a room
pub fn (cc ClientController) show_room_id() {
	if room := cc.current_room() {
		println('The room id of room "{room.name}" is {room.id}')
	} else {
		println('You are not in a room right now!')
	}
}

// create_room creates a new room on the server and displays the new room id to the user
pub fn (mut cc ClientController) create_room(command string) {
	splitted := command.split(' ')
	// error checking
	if splitted.len == 2 {
		println('You must provide a room name!\n":create room \$room_name" create a new room with name=\$room_name')
		cc.processing_command = false
		return
	}

	room_name := splitted[2..].join(' ')
	chats.send_command(mut cc.sock, 'create room {room_name}') or {
		eprintln(err)
		return
	}

	cc.command_callback = fn [mut cc] (data string) {
		defer {
			cc.processing_command = false
		}
		new_room := json.decode(chats.Room, data) or { return }

		// store the new room
		cc.rooms << new_room
		println('Created room "{new_room.name}" with id {new_room.id}')
	}
}

// add_room adds the user to a room if it exists
pub fn (mut cc ClientController) add_room(command string) {
	splitted := command.split(' ')
	// error checking
	if splitted.len == 2 {
		println('You must provide a room id!\n":add room \$room_id" add room with id="\$room_id"')
		cc.processing_command = false
		return
	}

	room_id := splitted[2].trim_space()
	chats.send_command(mut cc.sock, 'join {room_id}') or {
		eprintln(err)
		return
	}

	cc.command_callback = fn [mut cc, room_id] (data string) {
		if data == '' {
			println('Room with id {room_id} does not exist!')
			cc.processing_command = false
			return
		}
		cc.ls_rooms()
	}
}

// handle_comand calls the appropiate function for `command`
pub fn (mut cc ClientController) handle_command(command string) {
	if command == ':ls rooms' {
		cc.processing_command = true
		cc.ls_rooms()
	} else if command.starts_with(':join') {
		cc.processing_command = true
		cc.join(command)
	} else if command == ':leave' {
		cc.leave_room()
	} else if command == ':show current room' {
		cc.show_current_room()
	} else if command == ':help' {
		display_help()
	} else if command.starts_with(':dm') {
		cc.processing_command = true
		cc.dm(command)
	} else if command == ':show id' {
		println('Your user id is {cc.user.id}')
	} else if command == ':show room id' {
		cc.show_room_id()
	} else if command == ':show room users' {
		cc.processing_command = true
		cc.get_all_room_users()
	} else if command.starts_with(':create room') {
		cc.processing_command = true
		cc.create_room(command)
	} else if command.starts_with(':add room') {
		cc.processing_command = true
		cc.add_room(command)
	} else {
		println('Command "$command" not found!')
	}
}

// #endregion
// #region Core fucntionality
// ==========================

// handle_input requests input from the user and propogates the input accordingly
pub fn (mut cc ClientController) handle_input() {
	for {
		// we don't want to listen to input while a command is being processed. Else the terminal output will be ugly
		if cc.processing_command == true {
			continue
		}

		print('> ')
		input := os.get_line()

		// while this thread was waiting for input another thread could have closed the socket connection
		if cc.should_stop == true {
			return
		}

		if input == '' {
			continue
		} else if input == ':exit' {
			return
		} else if input[0] == `:` {
			cc.handle_command(input)
		} else {
			cc.send_message(input)
		}
	}
}

// send_message sends the `message` wrapped in appropiate headers to the server, which in turn delivers the message to any other user(s)
pub fn (mut cc ClientController) send_message(message string) {
	room := cc.current_room() or {
		eprintln('You need to join a room before you can send messages!')
		return
	}

	// construct and send the message headers
	message_headers := {
		'From':         cc.user.str()
		'Room':         room.id
		'Message':      message
		'Message-Type': 'room'
	}
	chats.send_message(mut cc.sock, message_headers) or { eprintln('Sending message failed!') }

	println('You: $message')
}

// handle_server processes any data sent from the server
pub fn (mut cc ClientController) handle_server() {
	for {
		// ignore any blank messages or write_ptr errors I'm not sure why they occur...
		event := chats.receive(mut cc.sock) or { continue }

		if event['Content-Type'] == 'string' && event['Content'] == chats.end_string {
			// close the connection
			println('Server: Connection was closed.')
			cc.should_stop = true
			cc.sock.close() or { panic(err) }
			return
		} else if event['Content-Type'] == 'command-reply' {
			cc.command_callback(event['Content'])
		} else if event['Content-Type'] == 'message' {
			cc.handle_incoming_message(event['Content'])
		}
	}
}

// handle_incoming_message processes any incoming messages from other users
pub fn (mut cc ClientController) handle_incoming_message(data string) {
	// ignore any empty strings or malformed data from the server
	message := json.decode(map[string]string, data) or { return }
	if message['From'] == cc.user.str() {
		return
	}

	if message['Message-Type'] == 'room' {
		current_room := cc.current_room() or { return }
		if current_room.id != message['Room'] {
			return
		}

		// we now know the message should be displayed tot the user, because he has joined the same room
		println('\n${message['From']}: ${message['Message']}')
	} else if message['Message-Type'] == 'dm' {
		println('\n(dm) ${message['From']}: ${message['Message']}')
	}

	print('> ')
}

// keep_alive keeps the connection alive by sending a ping message to the server
pub fn (mut cc ClientController) keep_alive() {
	for {
		time.sleep(5 * time.second)
		// if `chats.send` failed the socket connection has probably been closed, so we can return from the function
		chats.send(mut cc.sock, '', 'keep-alive') or { return }
	}
}

// #endregion
// #region Start script
// ====================

fn main() {
	println('
██╗    ██╗███████╗██╗      ██████╗ ██████╗ ███╗   ███╗███████╗    ████████╗ ██████╗       
██║    ██║██╔════╝██║     ██╔════╝██╔═══██╗████╗ ████║██╔════╝    ╚══██╔══╝██╔═══██╗      
██║ █╗ ██║█████╗  ██║     ██║     ██║   ██║██╔████╔██║█████╗         ██║   ██║   ██║      
██║███╗██║██╔══╝  ██║     ██║     ██║   ██║██║╚██╔╝██║██╔══╝         ██║   ██║   ██║      
╚███╔███╔╝███████╗███████╗╚██████╗╚██████╔╝██║ ╚═╝ ██║███████╗       ██║   ╚██████╔╝      
 ╚══╝╚══╝ ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝       ╚═╝    ╚═════╝       

██╗   ██╗       ██████╗██╗  ██╗ █████╗ ████████╗███████╗
██║   ██║      ██╔════╝██║  ██║██╔══██╗╚══██╔══╝██╔════╝
██║   ██║█████╗██║     ███████║███████║   ██║   ███████╗
╚██╗ ██╔╝╚════╝██║     ██╔══██║██╔══██║   ██║   ╚════██║
 ╚████╔╝       ╚██████╗██║  ██║██║  ██║   ██║   ███████║
  ╚═══╝         ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝
')
	// Get server ip and port from the user
	println('Please enter the chat-server address as ip:port')
	mut client := &net.TcpConn{}
	for {
		print('> ')
		addr := os.get_line()
		println('Trying to connect to ${addr}...')
		client = net.dial_tcp(addr) or {
			println("Can't connect to $addr, try again")
			continue
		}
		break
	}
	defer {
		client.close() or { panic(err) }
	}
	client.sock.set_option_bool(.keep_alive, true) or { return }

	println('Connected to ${client.peer_addr()!}')

	// Ask user for username
	println('Please enter your username')
	print('> ')
	username := os.get_line()

	// build user instance
	chats.send_string(mut client, username)!
	user_id := chats.receive_str(mut client) or {
		eprintln(err)
		return
	}
	println('Welcome $username!')
	println('Your user id is $user_id')
	mut user := chats.User{
		username: username
		id: user_id
	}

	mut client_controller := &ClientController{
		sock: mut client
		user: user
	}

	// display help send_string
	println('\nStart by creating a room, or direct message another user.')
	println('Here are some commands to help you on your way:')
	display_help()
	print('\n')

	go client_controller.handle_server()
	client_controller.handle_command(':ls rooms')

	go client_controller.keep_alive()
	client_controller.handle_input()

	println('Closing connection')
	chats.send_string(mut client, chats.end_string)!
}

// display_help displays a help message to the user
fn display_help() {
	println('":ls rooms" list all your chat rooms')
	println('":create room \$room_name" create a new room with name=\$room_name')
	println('":add room \$room_id" add room with id="\$room_id"')
	println('":join \$room_index" join a chat room')
	println('":show current room" show which room you are currently joined in')
	println('":show id" display your user id')
	println('":show room users" show all users that can access the room')
	println('":leave" leave the current room')
	println('":dm \$user \$message" send a direcet message. "\$user" can be a user id or their name in your contacts')
	println('":exit" stop the program')
	println('":help" show this message')
}

// #endregion
