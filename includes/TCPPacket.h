#ifndef TCPPACKET_H
#define TCPPACKET_H

#include "packet.h"

#define SYN 1
#define SYN_ACK 2
#define ACK 3
#define FIN 4
#define FIN_ACK 5
#define DATA 6
#define DATA_ACK 7
#define FINAL_ACK 8

    //TCP packet
    typedef nx_struct tcp_pack {
        nx_uint8_t srcPort;
        nx_uint8_t destPort;
        nx_uint16_t seq;
        nx_uint16_t ack;
        nx_uint16_t lastAck;
        nx_uint8_t flag;
        nx_uint16_t window;
        nx_uint8_t payload[20];
    }tcp_pack;

#endif