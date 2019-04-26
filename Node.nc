/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

//Implemented by Albert Nguyen

#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"
#include "includes/TCPPacket.h"

module Node {
    uses interface Boot;

    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface Random;
    uses interface Timer<TMilli> as periodicNeighbors;
    uses interface Timer<TMilli> as periodicLinkState;
    uses interface Timer<TMilli> as serverTimer;
    uses interface Timer<TMilli> as clientTimer;
    uses interface List<uint16_t> as neighborsList;
    uses interface Hashmap<uint16_t> as seqNumbers;
    uses interface Hashmap<uint8_t*> as linkState;
    uses interface Hashmap<uint16_t> as nodeDistance;
    uses interface Hashmap<uint16_t> as routeTable;
    uses interface SimpleSend as Sender;

    uses interface CommandHandler;
}

implementation {
    pack sendPackage;
    tcp_pack tcpPack;
    uint8_t transferBuff[128], readBuff[128];
    uint16_t i, j, k, l, m, minNode, min, data, currentTransfer, dataVal;
    uint16_t nodeNeighbors[64][64], oldNeighbors[64];
    uint32_t *destNode; 
    uint32_t *linkStateNodes;
    uint16_t *linkStateNeighbors;
    uint16_t nodeGraph[64][64];
    bool isConsidered[64], nextHopNeighbor;
    uint32_t timer, packetTimer, timeout;
    socket_t fd;
    socket_store_t sockets[MAX_NUM_OF_SOCKETS];
    socket_store_t newSocket, *tempSocket, acceptedSockets[MAX_NUM_OF_SOCKETS][MAX_NUM_OF_SOCKETS];
    socket_addr_t socketAddress;

    //Prototypes
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
    void makeTcpPack(tcp_pack *tcpPack, uint8_t srcPort, uint8_t destPort, uint16_t seq, uint16_t ack, uint16_t lastAck, uint8_t flag, uint16_t window, uint8_t *payload, uint8_t length);
    void updateRouteTable();
    socket_t socket();
    error_t bind(socket_t fileD, socket_addr_t *socketAddress);
    error_t connect(socket_t fileD, socket_addr_t *socketAddress);
    error_t listen(socket_t fileD);
    socket_t accept(socket_t fd);
    error_t close(socket_t fileD);
    uint16_t write(socket_t fileD, uint8_t *buff, uint16_t bufflen);
    uint16_t read(socket_t fileD, uint8_t *buff, uint16_t bufflen);
    error_t receive(pack* package);

    //on node start up
    event void Boot.booted() {
        call AMControl.start();
        makeTcpPack(&tcpPack, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        timer = (call Random.rand32() * 37) - (570000 * (TOS_NODE_ID - 10));
        call periodicNeighbors.startPeriodic(timer);
        call periodicLinkState.startPeriodic(timer + 10000);
        dbg(GENERAL_CHANNEL, "Booted\n");
    }

    event void AMControl.startDone(error_t err) {
        if(err == SUCCESS) {
            dbg(GENERAL_CHANNEL, "Radio On\n");
        }
        else{
            //Retry until successful
            call AMControl.start();
        }
    }

    event void AMControl.stopDone(error_t err) {}

    //when node receives a packet
    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
        pack* myMsg=(pack*) payload;
        logPack(myMsg);
        if(len==sizeof(pack)) {
            //if packet destination does not mach node
            if(TOS_NODE_ID != myMsg->dest) {
                //if source's sequence number is in map, compare sequence number in map to packet's
                if(call seqNumbers.contains(myMsg->src)) {
                    //if same/old packet was received, drop packet
                    if(myMsg->seq < call seqNumbers.get(myMsg->src)) {
                        dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                        return msg;
                    }
                }
                //if packet is a neighbor ping reply, then source is neighbor
                if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 0 && myMsg->protocol == PROTOCOL_PINGREPLY) {
                    dbg(FLOODING_CHANNEL, "Found Node %d as Neighbor\n", myMsg->src);
                    call neighborsList.pushfront(myMsg->src);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                }
                //drop packet if the source of the packet matches node or TTL is 0
                else if(TOS_NODE_ID == myMsg->src || myMsg->TTL == 0) {
                    dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                }   
                //if it is a neighbor ping, send out a neighbor ping reply
                else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 1 && myMsg->protocol == PROTOCOL_PING) {
                    if(!call seqNumbers.contains(TOS_NODE_ID)) {
                        call seqNumbers.insert(TOS_NODE_ID, 0);
                    }                    
                    dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping Reply\n");
                    makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 0, PROTOCOL_PINGREPLY, call seqNumbers.get(TOS_NODE_ID), myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, myMsg->src);
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                }
                //if it is a broadcasted link-state packet, store the information and flood
                else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->protocol == PROTOCOL_LINKSTATE) {
                    //copy array of neighbors from link-state packet into its own 2D array of node neighbors
                    i = 0;
                    linkStateNeighbors = myMsg->payload;
                    while(linkStateNeighbors[i] != 0) {
                        nodeNeighbors[myMsg->src][i] = linkStateNeighbors[i];  
                        i++;                  
                    }
                    nodeNeighbors[myMsg->src][i] = 0;  
                    //insert array of neighbors into link-state map
                    call linkState.insert(myMsg->src, nodeNeighbors[myMsg->src]);
                    //update route table and flood
                    updateRouteTable();
                    makePack(&sendPackage, myMsg->src, myMsg->dest, --myMsg->TTL, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    dbg(FLOODING_CHANNEL, "Packet Flooded\n"); 
                }               
                //forward if destination in route table
                else if(call routeTable.contains(myMsg->dest)) {
                    makePack(&sendPackage, myMsg->src, myMsg->dest, --myMsg->TTL, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, call routeTable.get(myMsg->dest));
                    dbg(FLOODING_CHANNEL, "Packet forwarded to Node %d\n", call routeTable.get(myMsg->dest));                        
                }
                //flood if destination not in route table
                else {
                    makePack(&sendPackage, myMsg->src, myMsg->dest, --myMsg->TTL, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    dbg(FLOODING_CHANNEL, "Packet Flooded\n"); 
                }
                call seqNumbers.insert(myMsg->src, myMsg->seq + 1); //update sequence number of packet source
                return msg;                     
            }
            //if packet destination matches node
            else { 
                //if source's sequence number is in map, compare sequence number in map to packet's
                if(call seqNumbers.contains(myMsg->src)) {
                    //if same/old packet was received, drop packet
                    if(myMsg->seq < call seqNumbers.get(myMsg->src)) {
                        dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                        return msg;
                    }
                }
                //if it is a ping reply, just read message
                if(myMsg->protocol == PROTOCOL_PINGREPLY) {
                    dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
                }
                //if it is a new ping, read message and send ping reply
                else if(myMsg->protocol == PROTOCOL_PING) {
                    dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
                    if(!call seqNumbers.contains(TOS_NODE_ID)) {
                        call seqNumbers.insert(TOS_NODE_ID, 0);
                    }
                    //send a ping reply
                    dbg(GENERAL_CHANNEL, "PING EVENT: REPLY \n");
                    makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, call seqNumbers.get(TOS_NODE_ID), myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    //send unicast ping reply if source of ping in route table, if not, broadcast
                    if(call routeTable.contains(myMsg->src)) {
                        call Sender.send(sendPackage, call routeTable.get(myMsg->src));
                        dbg(FLOODING_CHANNEL, "Packet sent to Node %d\n", call routeTable.get(myMsg->src));                        
                    }
                    else {  
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);         
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                }
                //if it is a tcp packet
                else if(myMsg->protocol == PROTOCOL_TCP) {  
                    receive(myMsg);
                }
                //error if packet protocol is not valid
                else {
                    dbg(GENERAL_CHANNEL, "ERROR: INVALID PACKET PROTOCOL\n");
                }
                call seqNumbers.insert(myMsg->src, myMsg->seq + 1);
                return msg;
            }
        }
        dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }

    //send a ping
    event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
        dbg(GENERAL_CHANNEL, "PING EVENT \n");
        if(!call seqNumbers.contains(TOS_NODE_ID)) {
            call seqNumbers.insert(TOS_NODE_ID, 0);
        }
        makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, call seqNumbers.get(TOS_NODE_ID), payload, PACKET_MAX_PAYLOAD_SIZE);
        //send unicast if destination of ping in route table, if not, broadcast
        if(call routeTable.contains(destination)) {
            call Sender.send(sendPackage, call routeTable.get(destination));
            dbg(FLOODING_CHANNEL, "Packet sent to Node %d\n", call routeTable.get(destination));                        
        }
        else {
            call Sender.send(sendPackage, AM_BROADCAST_ADDR);         
        }
        call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);  
    }

    //periodic neighbor discovery pings
    event void periodicNeighbors.fired() { 
        //reset neighbors list
        while(!(call neighborsList.isEmpty())) {
            call neighborsList.popback();
        }
        if(!call seqNumbers.contains(TOS_NODE_ID)) {
            call seqNumbers.insert(TOS_NODE_ID, 0);
        }
        //broadcast neighbor ping
        dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping\n");
        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, call seqNumbers.get(TOS_NODE_ID), "", PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
    }

    //periodic route table update and broadcast link-state packet
    event void periodicLinkState.fired() { 
        //update itself by inserting its own link-state/neighbors into link-state map
        for(i = 0; i < call neighborsList.size(); i++) {
            nodeNeighbors[TOS_NODE_ID][i] = call neighborsList.get(i);
        }
        nodeNeighbors[TOS_NODE_ID][call neighborsList.size()] = 0;
        call linkState.insert(TOS_NODE_ID, nodeNeighbors[TOS_NODE_ID]);
        //update route table then link-state broadcast
        updateRouteTable();
        dbg(GENERAL_CHANNEL, "Link-State Broadcast\n");
        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL, PROTOCOL_LINKSTATE, call seqNumbers.get(TOS_NODE_ID), nodeNeighbors[TOS_NODE_ID], PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
    }

    //print list of neighbor nodes
    event void CommandHandler.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "Neighbors of Node %d:\n", TOS_NODE_ID);
        dbg(NEIGHBOR_CHANNEL, "--------------------\n");
        for(i = 0; i < call neighborsList.size(); i++) {
            dbg(NEIGHBOR_CHANNEL, "       Node %d\n", call neighborsList.get(i));
        }
        dbg(NEIGHBOR_CHANNEL, "--------------------\n");
    }

    //using djkstra's algorithm make route table using given link-state info
    void updateRouteTable() {
        dbg(GENERAL_CHANNEL, "Updated Route Table\n");
        //reset route table
        destNode = call routeTable.getKeys();
        for(i = 0; i < call routeTable.size(); i++) {
            call routeTable.remove(destNode[i]);
        }
        //linkStateNodes are the nodes that sent link-state packets
        linkStateNodes = call linkState.getKeys();
        //go through each node to initialize node distance 
        for(i = 0; i < call linkState.size(); i++) {
            call nodeDistance.insert(linkStateNodes[i], 999);
            isConsidered[linkStateNodes[i]] = FALSE;
            linkStateNeighbors = call linkState.get(linkStateNodes[i]);
            j = 0;
            //go through each neighbor of node to build graph and set node distance of neighbors
            while(linkStateNeighbors[j] != 0) {
                nodeGraph[linkStateNodes[i]][linkStateNeighbors[j]] = 1;
                call nodeDistance.insert(linkStateNeighbors[j], 999);
                j++;
            }
        }
        //set distance of source node to 0
        call nodeDistance.insert(TOS_NODE_ID, 0);
        //find shortest path for the nodes
        for(i = 0; i < call linkState.size(); i++) {
            min = 999;
            //pick next minimum distance node not yet marked/calculated
            for(j = 0; j < call linkState.size(); j++) {
                if(!isConsidered[linkStateNodes[j]] && call nodeDistance.get(linkStateNodes[j]) <= min) {
                    min = call nodeDistance.get(linkStateNodes[j]);
                    minNode = linkStateNodes[j];
                }
            }
            j = 0;
            //mark the node
            isConsidered[minNode] = TRUE;
            //set variable to neighbors of considered node
            linkStateNeighbors = call linkState.get(minNode);
            //go through each neighbor of node and calculate distance values
            while(linkStateNeighbors[j] != 0) {
                if(!isConsidered[linkStateNeighbors[j]] && nodeGraph[minNode][linkStateNeighbors[j]] && call nodeDistance.get(minNode) != 999 
                && call nodeDistance.get(minNode) + nodeGraph[minNode][linkStateNeighbors[j]] < call nodeDistance.get(linkStateNeighbors[j])) {
                    //set node distance at node and insert which node is "closest" for next hop
                    call nodeDistance.insert(linkStateNeighbors[j], call nodeDistance.get(minNode) + nodeGraph[minNode][linkStateNeighbors[j]]);
                    call routeTable.insert(linkStateNeighbors[j], minNode);
                }
                j++;
            }
        }
        //use the global route table to make final route local table for itself
        destNode = call routeTable.getKeys();
        for(i = 0; i < call routeTable.size(); i++) {
            //if the next hop is itself, adjust route table to be next hop to destination is destination(these are neighbors of the root)
            if(call routeTable.get(destNode[i]) == TOS_NODE_ID) {
                call routeTable.insert(destNode[i], destNode[i]);
            }
            else{
                //if the next hop of destination is not a neighbor, adjust it 1 node at a time until the next hop is a neighbor
                nextHopNeighbor = FALSE;
                while(!nextHopNeighbor) {
                    for(j = 0; j < call neighborsList.size(); j++) {
                        if(call routeTable.get(destNode[i]) == call neighborsList.get(j)) {
                            nextHopNeighbor = TRUE;
                        }
                        else if(call routeTable.get(destNode[i]) == destNode[i]) {
                            nextHopNeighbor = TRUE;
                            j = call neighborsList.size();
                        }
                    }
                    if(!nextHopNeighbor) {
                        call routeTable.insert(destNode[i], call routeTable.get(call routeTable.get(destNode[i])));
                    }               
                } 
            }
        }
    }

    event void CommandHandler.printRouteTable() {
        destNode = call routeTable.getKeys();
        dbg(ROUTING_CHANNEL, "Destination   Next hop\n");
        dbg(ROUTING_CHANNEL, "----------------------\n");
        for(i = 0; i < call routeTable.size(); i++) {
            dbg(ROUTING_CHANNEL, "     %d           %d\n", destNode[i], call routeTable.get(destNode[i]));
        }
        dbg(ROUTING_CHANNEL, "----------------------\n");
    }

    event void CommandHandler.printLinkState() {
        dbg(ROUTING_CHANNEL, "Link-State Advertisements\n");
        //linkStateNodes are the nodes that sent link-state packets
        linkStateNodes = call linkState.getKeys();
        //go through each node
        for(i = 0; i < call linkState.size(); i++) {
            dbg(ROUTING_CHANNEL, "Neighbors of Node %d\n", linkStateNodes[i]);
            linkStateNeighbors = call linkState.get(linkStateNodes[i]);
            j = 0;
            //go through each neighbor of node to build graph
            while(linkStateNeighbors[j] != 0) {
                dbg(ROUTING_CHANNEL, "         %d\n", linkStateNeighbors[j]);
                j++;
            }
        }
    }

    event void CommandHandler.printDistanceVector(){}

    event void CommandHandler.setTestServer(uint8_t port) {
        fd = socket();
        socketAddress.addr = TOS_NODE_ID;
        socketAddress.port = port;
        if(bind(fd, &socketAddress) == SUCCESS) {
            if(listen(fd) == SUCCESS) {
                call serverTimer.startPeriodic(10000);
            }
            else {
                dbg(TRANSPORT_CHANNEL, "FAILED TO SET UP PORT TO LISTEN\n"); 
            }
        }
        else {
            dbg(TRANSPORT_CHANNEL, "FAILED TO SET UP TEST SERVER\n"); 
        }
    }

    event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
        fd = socket();
        socketAddress.addr = TOS_NODE_ID;
        socketAddress.port = srcPort;
        if(bind(fd, &socketAddress) == SUCCESS) {
            dbg(TRANSPORT_CHANNEL, "Socket binded to Port: %d\n", srcPort);
            socketAddress.addr = dest;
            socketAddress.port = destPort;
            if(connect(fd, &socketAddress) == SUCCESS) {
                dbg(TRANSPORT_CHANNEL, "Attempting to connect to Node: %d Port: %d...\n", dest, destPort);
                call clientTimer.startPeriodic(10000);
                currentTransfer = 1;
                data = transfer;
            }
        }
        else {
            dbg(TRANSPORT_CHANNEL, "FAILED TO SET UP TEST CLIENT\n");
        }
    }

    event void CommandHandler.closeTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort) {
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(srcPort == sockets[i].src && destPort == sockets[i].dest.port && dest == sockets[i].dest.addr) {
                close(i);
                break;
            }
        }
    }

    //creates socket
    socket_t socket() {
        static socket_t fileD = 0;
        if(fileD < MAX_NUM_OF_SOCKETS) {
            //initializes socket
            sockets[fileD] = socket_default;
            return fileD++; 
        }
        else {
            //find next available socket
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[fileD].state == 0) {
                    return i;
                }
            }
            return MAX_NUM_OF_SOCKETS;
        }
    }

    //bind socket to port
    error_t bind(socket_t fileD, socket_addr_t *socketAddress) {
        if(fileD < MAX_NUM_OF_SOCKETS && sockets[fileD].state == CLOSED) {
            sockets[fileD].dest = *socketAddress;
            return SUCCESS; 
        }
        else {
            dbg(TRANSPORT_CHANNEL, "Failed to bind. Current socket state: %d\n", sockets[fileD].state);
            return FAIL;
        }
    }
    
    error_t connect(socket_t fileD, socket_addr_t *socketAddress) {
        if(fileD < MAX_NUM_OF_SOCKETS && sockets[fileD].state == CLOSED) {
            //Send initial SYN
            makeTcpPack(&tcpPack, sockets[fileD].dest.port, socketAddress->port, 0, 0, 0, SYN, 8, "", PACKET_MAX_PAYLOAD_SIZE);
            makePack(&sendPackage, TOS_NODE_ID, socketAddress->addr, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)&tcpPack, PACKET_MAX_PAYLOAD_SIZE);
            //forward if destination in route table
            if(call routeTable.contains(socketAddress->addr)) {
                call Sender.send(sendPackage, call routeTable.get(socketAddress->addr));
                dbg(FLOODING_CHANNEL, "SYN Packet sent to Node %d\n", call routeTable.get(socketAddress->addr));                        
            }
            //flood if destination not in route table
            else {
                call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                dbg(FLOODING_CHANNEL, "SYN Packet Flooded\n"); 
            }
            call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
            sockets[fileD].state = SYN_SENT;
            packetTimer = call clientTimer.getNow();
            return SUCCESS; 
        }
        else {
            return FAIL;
        }
    }
    
    error_t listen(socket_t fileD) {
        if(fileD < MAX_NUM_OF_SOCKETS && sockets[fileD].state == CLOSED) {
            dbg(TRANSPORT_CHANNEL, "Port: %d is now listening\n", sockets[fileD].dest.port);
            sockets[fileD].state = LISTEN;
            return SUCCESS; 
        }
        else {
            return FAIL;
        }
    }

    socket_t accept(socket_t fileD) {
        if(sockets[fileD].state == ESTABLISHED) {
            return fileD;
        }
        else {
            return MAX_NUM_OF_SOCKETS; 
        }
    }

    error_t close(socket_t fileD) {
        if(fileD < MAX_NUM_OF_SOCKETS) {
            //if client, send FIN
            if(sockets[fileD].src != sockets[fileD].dest.port) {
                sockets[fileD].state = CLOSED;
                makeTcpPack(&tcpPack, sockets[fileD].src, sockets[fileD].dest.port, 0, 0, 0, FIN, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                makePack(&sendPackage, TOS_NODE_ID, sockets[fileD].dest.addr, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), "", PACKET_MAX_PAYLOAD_SIZE);
                //forward if destination in route table
                if(call routeTable.contains(sockets[fileD].dest.addr)) {
                    call Sender.send(sendPackage, call routeTable.get(sockets[fileD].dest.addr));
                    dbg(FLOODING_CHANNEL, "FIN Packet sent to Node %d\n", call routeTable.get(sockets[fileD].dest.addr));                        
                }
                //flood if destination not in route table
                else {
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    dbg(FLOODING_CHANNEL, "FIN Packet Flooded\n"); 
                }
                call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
            }
            //if server, just close
            else{
                sockets[fileD] = socket_default;
                return SUCCESS;    
            }
        }
        else {
            return FAIL;
        }
    }

    //write buff to socket
    uint16_t write(socket_t fileD, uint8_t *buff, uint16_t bufflen) {
        if(bufflen > 128) {
            j = 128;
        }
        else {
            j = bufflen;
        }
        k = 0;
        l = 0;
        for(i = sockets[fileD].lastWritten % 127; i < (sockets[fileD].lastWritten + j); i++) {
            if(sockets[fileD].flag == 1) {
                sockets[fileD].sendBuff[i % 128] = buff[k];
                sockets[fileD].sendBuff[(i + 1) % 128] = buff[k+1];
                k += 2;
                i++;
            }
            else {
                sockets[fileD].sendBuff[i % 128] = buff[k];
                k++;
            }
            l++;
            dbg(TRANSPORT_CHANNEL, "%d, \n", sockets[fileD].sendBuff[i]);
        }
        sockets[fileD].lastWritten = i;
        dbg(TRANSPORT_CHANNEL, "%d Written\n", l);
        return l;
    }

    //write socket to buff and read buff
    uint16_t read(socket_t fileD, uint8_t *buff, uint16_t bufflen) {
        if(bufflen > 128) {
            j = 128;
        }
        else{
            j = bufflen;
        }
        //find correct accepted client socket for sendBuff
        tempSocket = acceptedSockets[fileD];
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i ++) {
            if(sockets[fileD].src == tempSocket[i].src && sockets[fileD].dest.addr == tempSocket[i].dest.addr && sockets[fileD].dest.port == tempSocket[i].dest.port) {
                newSocket = tempSocket[i];
                k = i;
                i = MAX_NUM_OF_SOCKETS;
            }
        }
        buff = newSocket.rcvdBuff;
        l = 0;
        m = (newSocket.lastRead + 1) % 128;
        if(newSocket.lastRead == 0 && buff[0] == 1 && buff[1] == 2) {
            m--;
        }
        dbg(TRANSPORT_CHANNEL, "Reading Data:\n");
        for(i = newSocket.lastRead; i < (newSocket.lastRead + j); i++) {
            dataVal = 0;
            if(buff[m] == 255 && buff[m-1] == 255) {
                newSocket.flag = 1;
            }
            if(newSocket.flag == 1) {
                dataVal = buff[m];
                dataVal = dataVal << 8;
                dataVal |= buff[(m+1) % 128];
                i++;
            }
            else {
                dataVal = buff[m];
            }
            dbg(TRANSPORT_CHANNEL, "%d, \n", dataVal);
            l++;
            m = (m + 1) % 128;
        }
        newSocket.lastRead = m;
        acceptedSockets[fileD][k] = newSocket;
        return l;
    }

    error_t receive(pack* package) {
        tcp_pack *tcp = (tcp_pack*)package->payload;
        dbg(TRANSPORT_CHANNEL, "TCP Packet Received with Flag: %hhu SrcPort: %hhu DestPort: %hhu\n", tcp->flag, tcp->srcPort, tcp->destPort);
        if(tcp->flag == SYN) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].dest.port == tcp->destPort && sockets[i].state == LISTEN) {
                    //send SYN_ACK
                    makeTcpPack(&tcpPack, sockets[i].dest.port, tcp->srcPort, 0, 0, 0, SYN_ACK, 6, "", PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, package->src, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    //forward if destination in route table
                    if(call routeTable.contains(package->src)) {
                        call Sender.send(sendPackage, call routeTable.get(package->src));
                        dbg(GENERAL_CHANNEL, "SYN_ACK Packet sent to Node %d\n", call routeTable.get(package->src));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "SYN_ACK Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    sockets[i].state = SYN_RCVD;
                    packetTimer = call serverTimer.getNow();
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == SYN_ACK) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].dest.port == tcp->destPort && sockets[i].state == SYN_SENT) {
                    //send ACK
                    makeTcpPack(&tcpPack, sockets[i].dest.port, tcp->srcPort, 0, 0, 0, ACK, tcp->window, "", PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, package->src, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    //forward if destination in route table
                    if(call routeTable.contains(package->src)) {
                        call Sender.send(sendPackage, call routeTable.get(package->src));
                        dbg(GENERAL_CHANNEL, "ACK Packet sent to Node %d\n", call routeTable.get(package->src));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "ACK Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    //establish connection and send first data
                    sockets[i].effectiveWindow = tcp->window;
                    sockets[i].dest.port = tcp->srcPort;
                    sockets[i].dest.addr = package->src;
                    sockets[i].src = tcp->destPort;
                    sockets[i].state = ESTABLISHED;
                    dbg(TRANSPORT_CHANNEL, "Test Client is now ESTABLISHED\n");
                    for(j = 0; j < 128; j++) {
                        transferBuff[j] = currentTransfer++;
                    }
                    fd = i;
                    data -= write(i, transferBuff, data);
                    i = fd;
                    makeTcpPack(&tcpPack, sockets[i].src, sockets[i].dest.port, 0, 0, 0, DATA, tcp->window, sockets[i].sendBuff + tcp->ack, PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, sockets[i].dest.addr, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    sockets[i].lastSent += (sockets[i].effectiveWindow - 1) % 128;
                    //forward if destination in route table
                    if(call routeTable.contains(sockets[i].dest.addr)) {
                        call Sender.send(sendPackage, call routeTable.get(sockets[i].dest.addr));
                        dbg(GENERAL_CHANNEL, "First DATA Packet sent to Node %d\n", call routeTable.get(sockets[i].dest.addr));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "First DATA Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    sockets[i].RTT = call clientTimer.getNow() - packetTimer;
                    timeout = 2 * sockets[i].RTT;
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == ACK) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].dest.port == tcp->destPort && sockets[i].state == SYN_RCVD) {
                    //Establish server and add accepted socket
                    sockets[i].effectiveWindow = tcp->window;
                    sockets[i].src = sockets[i].dest.port;
                    sockets[i].state = ESTABLISHED;
                    newSocket = sockets[i];
                    newSocket.dest.port = tcp->srcPort;
                    newSocket.dest.addr = package->src;
                    //insert client socket into next available index of accepted sockets of server
                    tempSocket = acceptedSockets[i];
                    for(j = 0; j < MAX_NUM_OF_SOCKETS; j++) {
                        if(sockets[i].src != tempSocket[j].src) {
                            acceptedSockets[i][j] = newSocket;
                            j = MAX_NUM_OF_SOCKETS;
                        }
                    }
                    dbg(TRANSPORT_CHANNEL, "Test Server is now ESTABLISHED\n");
                    sockets[i].RTT = call serverTimer.getNow()- packetTimer;
                    timeout = 2 * sockets[i].RTT;
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == FIN) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].src == tcp->destPort && sockets[i].state == ESTABLISHED) {
                    //send FIN_ACK
                    makeTcpPack(&tcpPack, sockets[i].src, tcp->srcPort, (tcpPack.seq % 255) + 1, tcpPack.ack, tcpPack.lastAck, FIN_ACK, tcp->window, "", PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, package->src, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    //forward if destination in route table
                    if(call routeTable.contains(sockets[i].dest.addr)) {
                        call Sender.send(sendPackage, call routeTable.get(sockets[i].dest.addr));
                        dbg(FLOODING_CHANNEL, "FIN_ACK Packet sent to Node %d\n", call routeTable.get(sockets[i].dest.addr));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "FIN_ACK Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == FIN_ACK) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].src == tcp->destPort && sockets[i].state == ESTABLISHED) {
                    //send FINAL_ACK
                    makeTcpPack(&tcpPack, sockets[i].src, sockets[i].dest.port, (tcpPack.seq % 255) + 1, tcpPack.ack, tcpPack.lastAck, FINAL_ACK, tcp->window, "", PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, sockets[i].dest.addr, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    //forward if destination in route table
                    if(call routeTable.contains(sockets[i].dest.addr)) {
                        call Sender.send(sendPackage, call routeTable.get(sockets[i].dest.addr));
                        dbg(FLOODING_CHANNEL, "FINAL_ACK Packet sent to Node %d\n", call routeTable.get(sockets[i].dest.addr));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "FINAL_ACK Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == FINAL_ACK) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].src == tcp->destPort && sockets[i].state == ESTABLISHED) {
                    tempSocket = acceptedSockets[i];
                    for(j = 0; j < MAX_NUM_OF_SOCKETS; j++) {
                        if(sockets[i].src == tempSocket[j].src && tcp->srcPort == tempSocket[j].dest.port) {   
                            acceptedSockets[i][j] = null_socket;
                        }
                    }
                    close(i);
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == DATA) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].src == tcp->destPort && sockets[i].state == ESTABLISHED) {
                    //put payload data into sendBUff
                    tempSocket = acceptedSockets[i];
                    for(j = 0; j < MAX_NUM_OF_SOCKETS; j++) {
                        if(sockets[i].src == tempSocket[j].src && tcp->srcPort == tempSocket[j].dest.port) {   
                            newSocket = tempSocket[j];
                            l = j;
                            j = MAX_NUM_OF_SOCKETS;
                        }
                    }
                    k = 0;
                    for(j = newSocket.lastRcvd; j < (newSocket.lastRcvd + tcp->window); j++) {
                        m = j;
                        if(j >= 128) {
                            m = j % 128;
                        }
                        if(newSocket.flag == 1) {
                            newSocket.sendBuff[m] = tcp->payload[k];
                            k++;
                        }
                        else {
                            newSocket.sendBuff[m] = tcp->payload[k];
                            newSocket.sendBuff[(m+1) % 128] = tcp->payload[k+1];
                            k += 2;                            
                        }
                    }
                    newSocket.lastRcvd = m;
                    newSocket.nextExpected = (newSocket.lastRcvd + 1) % 128;
                    acceptedSockets[i][l] = newSocket;
                    //send DATA_ACK
                    makeTcpPack(&tcpPack, tcp->destPort, tcp->srcPort, 0, newSocket.nextExpected, 0, DATA_ACK, tcp->window, "", PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, package->src, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    //forward if destination in route table
                    if(call routeTable.contains(package->src)) {
                        call Sender.send(sendPackage, call routeTable.get(package->src));
                        dbg(FLOODING_CHANNEL, "DATA_ACK Packet sent to Node %d\n", call routeTable.get(package->src));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "DATA_ACK Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else if(tcp->flag == DATA_ACK) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].src == tcp->destPort && sockets[i].dest.port == tcp-> srcPort && sockets[i].state == ESTABLISHED) {
                    //send DATA
                    if(sockets[i].lastSent > tcp->ack) {
                        call clientTimer.startOneShot(0);
                    }
                    sockets[i].lastAck = (tcp->ack - 1) % 128; 
                    makeTcpPack(&tcpPack, sockets[i].src, sockets[i].dest.port, tcp->ack, 0, tcp->ack, DATA, tcp->window, sockets[i].sendBuff + tcp->ack, PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, TOS_NODE_ID, sockets[i].dest.addr, MAX_TTL, PROTOCOL_TCP, call seqNumbers.get(TOS_NODE_ID), (uint8_t*)(&tcpPack), PACKET_MAX_PAYLOAD_SIZE);
                    sockets[i].lastSent += (sockets[i].effectiveWindow - 1) % 128;
                    //forward if destination in route table
                    if(call routeTable.contains(sockets[i].dest.addr)) {
                        call Sender.send(sendPackage, call routeTable.get(sockets[i].dest.addr));
                        dbg(FLOODING_CHANNEL, "DATA Packet sent to Node %d\n", call routeTable.get(sockets[i].dest.addr));                        
                    }
                    //flood if destination not in route table
                    else {
                        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                        dbg(FLOODING_CHANNEL, "DATA Packet Flooded\n"); 
                    }
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                    return SUCCESS;
                }
            }
            return FAIL;
        }
        else {
            return FAIL;
        }
    }

    event void serverTimer.fired() {
        socket_t newFd = accept(fd);
        if(newFd < MAX_NUM_OF_SOCKETS) {
            tempSocket = acceptedSockets[newFd];
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i ++) {
                if(sockets[newFd].src == tempSocket[i].src && tempSocket[i].lastRead != tempSocket[i].lastRcvd) {
                    sockets[newFd].dest = tempSocket[i].dest;
                    read(newFd, readBuff, tempSocket[i].lastRcvd - tempSocket[i].lastRead + 1);
                }
            }
        }
    }

    event void clientTimer.fired() {
        dbg(TRANSPORT_CHANNEL, "Writing...\n");
        do {
            if(sockets[fd].lastSent % 127 == 0 || sockets[fd].lastAck % 127 == 0) {
                for(i = 0; i < 128; i++) {
                    if(currentTransfer > 255) {
                        sockets[fd].flag = 1;
                        transferBuff[i] = currentTransfer >> 8;
                        transferBuff[i+1] = currentTransfer & 0x00FF;
                        currentTransfer++;
                        i++;
                    }
                    else {
                        transferBuff[i] = currentTransfer++;
                    }
                }
                data -= write(fd, transferBuff, data);
            }
        } while(data != 0);
        if(data == 0 && sockets[fd].lastAck == sockets[fd].lastSent && sockets[fd].state != CLOSED) {
            close(fd);
            dbg(TRANSPORT_CHANNEL, "CLOSING CLIENT\n");
        }
    }

    event void CommandHandler.setAppServer(){}

    event void CommandHandler.setAppClient(){}

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }

    void makeTcpPack(tcp_pack *tcpPack, uint8_t srcPort, uint8_t destPort, uint16_t seq, uint16_t ack, uint16_t lastAck, uint8_t flag, uint16_t window, uint8_t *payload, uint8_t length) {
        tcpPack->srcPort = srcPort;
        tcpPack->destPort = destPort;
        tcpPack->seq = seq;
        tcpPack->ack = ack;
        tcpPack->lastAck = lastAck;
        tcpPack->flag = flag;
        tcpPack->window = window;
        memcpy(tcpPack->payload, payload, length);
    }
}