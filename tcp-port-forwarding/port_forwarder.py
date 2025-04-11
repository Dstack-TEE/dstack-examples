#!/usr/bin/env python3
import socket
import ssl
import threading
import select
import sys
import argparse

def parse_address(address):
    """Parse an address in the format 'host:port'"""
    parts = address.split(':')
    if len(parts) != 2:
        raise ValueError(f"Invalid address format: {address}. Use format 'host:port'")

    host = parts[0]
    try:
        port = int(parts[1])
        if port < 1 or port > 65535:
            raise ValueError(f"Invalid port number: {port}. Must be between 1 and 65535")
    except ValueError:
        raise ValueError(f"Port must be a number between 1 and 65535, got: {parts[1]}")

    return (host, port)

def handle_client(client_socket, remote_host, remote_port):
    """Handle a client connection by forwarding it to the remote server with TLS"""
    print(f"New connection from {client_socket.getpeername()}")

    # Create TLS context
    context = ssl.create_default_context()

    try:
        # Connect to the remote server with TLS
        remote_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        secured_socket = context.wrap_socket(remote_socket, server_hostname=remote_host)
        secured_socket.connect((remote_host, remote_port))

        print(f"Connected to {remote_host}:{remote_port} with TLS")

        # Forward data in both directions
        while True:
            # Use select to monitor both sockets
            readable, _, exceptional = select.select([client_socket, secured_socket], [], [client_socket, secured_socket], 60)

            if exceptional:
                print("Connection error")
                break

            for sock in readable:
                if sock is client_socket:
                    # Receive from client, send to server
                    data = client_socket.recv(4096)
                    if not data:
                        print("Client disconnected")
                        return
                    secured_socket.send(data)

                elif sock is secured_socket:
                    # Receive from server, send to client
                    data = secured_socket.recv(4096)
                    if not data:
                        print("Server disconnected")
                        return
                    client_socket.send(data)

    except Exception as e:
        print(f"Error: {e}")

    finally:
        try:
            client_socket.close()
            secured_socket.close()
        except:
            pass
        print("Connection closed")

def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='TCP to TLS proxy')
    parser.add_argument('-l', '--local', required=True, help='Local address to listen on (format: host:port)')
    parser.add_argument('-r', '--remote', required=True, help='Remote address to connect to (format: host:port)')

    args = parser.parse_args()

    try:
        local_host, local_port = parse_address(args.local)
        remote_host, remote_port = parse_address(args.remote)

        # Create server socket
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((local_host, local_port))
        server.listen(5)

        print(f"TLS proxy listening on {local_host}:{local_port}")
        print(f"Forwarding to {remote_host}:{remote_port} with TLS")
        print("Press Ctrl+C to exit")

        while True:
            client_socket, addr = server.accept()
            client_thread = threading.Thread(
                target=handle_client,
                args=(client_socket, remote_host, remote_port)
            )
            client_thread.daemon = True
            client_thread.start()

    except KeyboardInterrupt:
        print("\nShutting down...")

    except Exception as e:
        print(f"Error: {e}")

    finally:
        try:
            server.close()
        except:
            pass

if __name__ == "__main__":
    main()
