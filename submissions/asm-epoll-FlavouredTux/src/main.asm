; main.asm - Entry point and Linux epoll event loop in x86_64 NASM
default rel

%include "common.inc"

; External libc functions
extern getenv
extern atoi
extern htons
extern inet_pton
extern socket
extern setsockopt
extern bind
extern listen
extern accept4
extern epoll_create1
extern epoll_ctl
extern epoll_wait
extern read
extern write
extern close
extern mmap
extern signal
extern clock_gettime
extern printf
extern exit
extern strlen
extern memcpy

; External module functions & data
extern init_db
extern handle_http_request
extern server_start_time
extern jwt_secret_buf
extern jwt_secret_len

%define SIGPIPE         13
%define SIG_IGN         1

%define PROT_READ       1
%define PROT_WRITE      2
%define MAP_PRIVATE     2
%define MAP_ANONYMOUS   0x20

; epoll_event is 12 bytes packed on x86_64 Linux:
; events: uint32_t (4 bytes)
; data: epoll_data_t (8 bytes)
struc epoll_event_s
    .events     resd 1
    .data_fd    resd 1
    .data_pad   resd 1
endstruc

section .rodata
env_sqlite_path:    db "SQLITE_PATH", 0
env_jwt_secret:     db "JWT_SECRET", 0
env_host:           db "HOST", 0
env_port:           db "PORT", 0

def_sqlite_path:    db "feed.db", 0
def_jwt_secret:     db "twelve-dollar-challenge", 0
def_host:           db "127.0.0.1", 0
def_port:           db "3000", 0

str_start_msg:      db "Starting ASM epoll server on %s:%d (db: %s)...", 10, 0
str_db_err:         db "Error: Failed to initialize SQLite database at %s", 10, 0
str_sock_err:       db "Error: Failed to create/bind listening socket", 10, 0

section .bss
global listen_fd
global epoll_fd
global conn_table
global resp_buffer
global active_conns

listen_fd:          resd 1
epoll_fd:           resd 1
active_conns:       resd 1
conn_table:         resq 1      ; pointer to mmap'd table of MAX_FDS * sizeof(conn_state)
resp_buffer:        resb RESP_BUF_SIZE

; Events buffer for epoll_wait (1024 * 12 bytes = 12288 bytes)
epoll_events_buf:   resb (MAX_EVENTS * 12)

section .text
global main

; =============================================================================
; close_client(int fd [edi])
; =============================================================================
close_client:
    push rbx
    push rbp
    mov rbp, rsp
    mov ebx, edi            ; fd

    ; Decrement active_conns
    cmp dword [active_conns], 0
    jle .skip_dec
    dec dword [active_conns]
.skip_dec:

    ; Remove from epoll
    mov edi, [epoll_fd]
    mov esi, EPOLL_CTL_DEL
    mov edx, ebx
    xor ecx, ecx
    call epoll_ctl

    ; Close socket
    mov edi, ebx
    call close

    ; Reset conn_state.read_len = 0
    mov rax, [conn_table]
    mov rdx, conn_state_size
    imul rdx, rbx
    mov qword [rax + rdx + conn_state.read_len], 0

    leave
    pop rbx
    ret

; =============================================================================
; main()
; =============================================================================
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88             ; 5 pushes (40) + 88 = 128 (16-byte aligned!)

    ; 1. Ignore SIGPIPE
    mov edi, SIGPIPE
    mov esi, SIG_IGN
    call signal

    ; 2. Record server_start_time
    sub rsp, 16
    mov edi, 1              ; CLOCK_MONOTONIC
    mov rsi, rsp
    call clock_gettime
    mov rax, [rsp]          ; tv_sec
    mov [server_start_time], rax
    add rsp, 16

    ; 3. Read Environment Variables
    ; SQLITE_PATH
    lea rdi, [env_sqlite_path]
    call getenv
    test rax, rax
    jnz .have_sqlite_path
    lea rax, [def_sqlite_path]
.have_sqlite_path:
    mov [rbp - 48], rax     ; sqlite_path ptr

    ; JWT_SECRET
    lea rdi, [env_jwt_secret]
    call getenv
    test rax, rax
    jnz .have_jwt_secret
    lea rax, [def_jwt_secret]
.have_jwt_secret:
    mov [rbp - 56], rax     ; jwt_secret ptr

    ; Copy JWT_SECRET to jwt_secret_buf
    mov rdi, rax
    call strlen
    mov [jwt_secret_len], rax
    lea rdi, [jwt_secret_buf]
    mov rsi, [rbp - 56]
    mov rdx, [jwt_secret_len]
    call memcpy
    mov rax, [jwt_secret_len]
    mov byte [jwt_secret_buf + rax], 0

    ; HOST
    lea rdi, [env_host]
    call getenv
    test rax, rax
    jnz .have_host
    lea rax, [def_host]
.have_host:
    mov [rbp - 64], rax     ; host ptr

    ; PORT
    lea rdi, [env_port]
    call getenv
    test rax, rax
    jnz .have_port
    lea rax, [def_port]
.have_port:
    mov rdi, rax
    call atoi
    mov [rbp - 68], eax     ; port int

    ; 4. Print banner
    lea rdi, [str_start_msg]
    mov rsi, [rbp - 64]     ; host
    mov edx, [rbp - 68]     ; port
    mov rcx, [rbp - 48]     ; db path
    xor eax, eax
    call printf

    ; 5. Initialize SQLite Database
    mov rdi, [rbp - 48]
    call init_db
    test eax, eax
    jz .db_ok
    lea rdi, [str_db_err]
    mov rsi, [rbp - 48]
    xor eax, eax
    call printf
    mov edi, 1
    call exit

.db_ok:
    ; 6. Allocate Connection Table using mmap (demand-paged)
    ; size = MAX_FDS * sizeof(conn_state)
    xor edi, edi            ; addr = NULL
    mov rsi, MAX_FDS
    mov rdx, conn_state_size
    imul rsi, rdx           ; total bytes
    mov edx, PROT_READ | PROT_WRITE
    mov ecx, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1              ; fd = -1
    xor r9, r9              ; offset = 0
    call mmap
    mov [conn_table], rax

    ; 7. Create Listening Socket
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    call socket
    cmp eax, 0
    jl .sock_fail
    mov [listen_fd], eax
    mov ebx, eax            ; listen_fd

    ; Set SO_REUSEADDR
    sub rsp, 16
    mov dword [rsp], 1
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    mov rcx, rsp
    mov r8d, 4
    call setsockopt

    ; Set SO_REUSEPORT
    mov dword [rsp], 1
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEPORT
    mov rcx, rsp
    mov r8d, 4
    call setsockopt

    ; Set TCP_NODELAY
    mov dword [rsp], 1
    mov edi, ebx
    mov esi, IPPROTO_TCP
    mov edx, TCP_NODELAY
    mov rcx, rsp
    mov r8d, 4
    call setsockopt
    add rsp, 16

    ; Construct struct sockaddr_in (16 bytes)
    ; [rbp - 32]: sin_family (2), sin_port (2), sin_addr (4), sin_zero (8)
    lea rdi, [rbp - 32]
    mov rcx, 16
    xor eax, eax
.zero_sin:
    mov byte [rdi + rcx - 1], 0
    loop .zero_sin

    mov word [rbp - 32], AF_INET

    ; htons(port)
    mov edi, [rbp - 68]
    call htons
    mov word [rbp - 30], ax

    ; inet_pton(AF_INET, host, &sin_addr)
    mov edi, AF_INET
    mov rsi, [rbp - 64]
    lea rdx, [rbp - 28]     ; &sin_addr
    call inet_pton

    ; Bind
    mov edi, ebx
    lea rsi, [rbp - 32]
    mov edx, 16
    call bind
    test eax, eax
    jnz .sock_fail

    ; Listen
    mov edi, ebx
    mov esi, 4096
    call listen
    test eax, eax
    jnz .sock_fail

    ; 8. Create Epoll Instance
    mov edi, EPOLL_CLOEXEC
    call epoll_create1
    cmp eax, 0
    jl .sock_fail
    mov [epoll_fd], eax
    mov r12d, eax           ; epoll_fd

    ; Add listen_fd to epoll
    sub rsp, 16             ; struct epoll_event (12 bytes)
    mov dword [rsp + epoll_event_s.events], EPOLLIN
    mov eax, [listen_fd]
    mov dword [rsp + epoll_event_s.data_fd], eax
    mov dword [rsp + epoll_event_s.data_pad], 0

    mov edi, r12d
    mov esi, EPOLL_CTL_ADD
    mov edx, [listen_fd]
    mov rcx, rsp
    call epoll_ctl
    add rsp, 16

    ; =========================================================================
    ; 9. Main Event Loop
    ; =========================================================================
.event_loop:
    mov edi, [epoll_fd]
    lea rsi, [epoll_events_buf]
    mov edx, MAX_EVENTS
    mov ecx, -1             ; timeout: infinite
    call epoll_wait
    cmp eax, 0
    jle .event_loop          ; interrupted or no events

    mov r13d, eax           ; number of ready events
    xor r14d, r14d          ; event index (0 .. r13d - 1)

.process_events:
    cmp r14d, r13d
    jge .event_loop

    ; events[r14] offset = r14 * 12
    mov rax, r14
    imul rax, 12
    lea r15, [epoll_events_buf + rax]

    mov ebx, [r15 + epoll_event_s.data_fd]
    mov eax, [r15 + epoll_event_s.events]

    ; Check if event is on listen_fd
    cmp ebx, [listen_fd]
    je .handle_accept

    ; Client Socket Event
    ; Check errors / hangup
    test eax, (EPOLLERR | EPOLLHUP | EPOLLRDHUP)
    jnz .client_disconnect

    ; Check EPOLLIN
    test eax, EPOLLIN
    jnz .handle_client_read

    inc r14d
    jmp .process_events

.client_disconnect:
    mov edi, ebx
    call close_client
    inc r14d
    jmp .process_events

.handle_accept:
    ; Loop accept4 until EAGAIN
.accept_loop:
    mov edi, [listen_fd]
    xor esi, esi
    xor edx, edx
    mov ecx, SOCK_NONBLOCK | SOCK_CLOEXEC
    call accept4
    cmp eax, 0
    jl .accept_done

    mov ebx, eax            ; new client_fd
    cmp ebx, MAX_FDS
    jge .reject_client


    ; Add client to epoll
    ; events = EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP
    mov dword [rbp - 112 + epoll_event_s.events], (EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP)
    mov dword [rbp - 112 + epoll_event_s.data_fd], ebx
    mov dword [rbp - 112 + epoll_event_s.data_pad], 0

    mov edi, [epoll_fd]
    mov esi, EPOLL_CTL_ADD
    mov edx, ebx
    lea rcx, [rbp - 112]
    call epoll_ctl

    ; Initialize conn_state
    mov rax, [conn_table]
    mov rdx, conn_state_size
    imul rdx, rbx
    mov dword [rax + rdx + conn_state.fd], ebx
    mov qword [rax + rdx + conn_state.read_len], 0
    inc dword [active_conns]

    jmp .accept_loop

.reject_client:
    mov edi, ebx
    call close
    jmp .accept_loop

.accept_done:
    inc r14d
    jmp .process_events

.handle_client_read:
    ; Pointer to client conn_state
    mov rax, [conn_table]
    mov rdx, conn_state_size
    imul rdx, rbx
    lea r12, [rax + rdx]    ; r12 = conn_state*

    mov rax, [r12 + conn_state.read_len]
    cmp rax, REQ_BUF_SIZE
    jge .client_disconnect  ; buffer full

    ; read(client_fd, read_buf + read_len, REQ_BUF_SIZE - read_len)
    mov edi, ebx
    lea rsi, [r12 + conn_state.read_buf]
    mov rdx, [r12 + conn_state.read_len]
    add rsi, rdx            ; buf + read_len
    mov rdx, REQ_BUF_SIZE
    sub rdx, [r12 + conn_state.read_len]
    call read
    cmp eax, 0
    jle .client_disconnect  ; EOF or error

    ; Update read_len
    cdqe
    add [r12 + conn_state.read_len], rax

    ; Check if request contains \r\n\r\n or \n\n
    mov rsi, [r12 + conn_state.read_len]
    lea rdi, [r12 + conn_state.read_buf]
    xor ecx, ecx
    xor edx, edx            ; header_end flag

.scan_header_end:
    lea rax, [rcx + 4]
    cmp rax, rsi
    jg .check_lf_lf
    ; \r\n\r\n = 0x0A0D0A0D
    mov eax, [rdi + rcx]
    cmp eax, 0x0a0d0a0d
    je .found_end
    inc rcx
    jmp .scan_header_end

.check_lf_lf:
    lea rax, [rcx + 2]
    cmp rax, rsi
    jg .need_more_data
    cmp word [rdi + rcx], 0x0a0a
    je .found_end
    inc rcx
    jmp .check_lf_lf

.found_end:
    mov edx, 1

.need_more_data:
    test edx, edx
    jz .next_ready_event    ; incomplete request, wait for next EPOLLIN

    ; We have a complete request header!
    ; Call handle_http_request
    sub rsp, 32
    lea rdi, [r12 + conn_state.read_buf]
    mov rsi, [r12 + conn_state.read_len]
    lea rdx, [resp_buffer]
    lea rcx, [rsp]          ; out_resp_len
    lea r8, [rsp + 8]       ; out_keep_alive
    call handle_http_request

    mov r15, [rsp]          ; resp_len
    mov eax, [rsp + 8]      ; keep_alive
    add rsp, 32
    push rax                ; preserve keep_alive across write

    ; Write response to socket
    mov edi, ebx
    lea rsi, [resp_buffer]
    mov rdx, r15
    call write

    pop rax                 ; restore keep_alive
    ; If keep_alive == 0, close connection
    test eax, eax
    jz .close_conn

    ; Keep-alive: reset read_len = 0 for next request
    mov qword [r12 + conn_state.read_len], 0
    jmp .next_ready_event

.close_conn:
    mov edi, ebx
    call close_client

.next_ready_event:
    inc r14d
    jmp .process_events

.sock_fail:
    lea rdi, [str_sock_err]
    xor eax, eax
    call printf
    mov edi, 1
    call exit
