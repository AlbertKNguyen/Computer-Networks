/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"


module Node {
    uses interface Boot;

    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface Random;
    uses interface Timer<TMilli> as periodicTimer;
    uses interface List<uint16_t> as seqNumber;
    uses interface List<pack> as packetSeen;
    uses interface List<uint16_t> as neighbors;
    uses interface SimpleSend as Sender;

    uses interface CommandHandler;
}

implementation {
    pack sendPackage;
    uint16_t count;
    pack srcSeq;
    // Prototypes
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    //on node start up
    event void Boot.booted() {
        call AMControl.start();
        call periodicTimer.startPeriodic((call Random.rand32() * 37) - (570000 * (TOS_NODE_ID - 10)));
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
        dbg(GENERAL_CHANNEL, "Packet Received. Src: %d Dest: %d TTL: %d Protocol: %d Seq: %d\n",  myMsg->src, myMsg->dest, myMsg->TTL, myMsg->protocol, myMsg->seq);
        if(len==sizeof(pack)) {
            //if packet destination does not mach node
            if(TOS_NODE_ID != myMsg->dest) {
                //if packet is a neighbor ping reply, then source is neighbor
                if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 0 && myMsg->protocol == 1) {
                    dbg(FLOODING_CHANNEL, "Found Node %d as Neighbor\n", myMsg->src);
                    call neighbors.pushfront(myMsg->src);
                    call packetSeen.pushfront(*myMsg);
                    return msg;
                }
                //drop packet if the source of the packet matches node or TTL is 0
                else if(TOS_NODE_ID == myMsg->src || myMsg->TTL == 0) {
                    dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                    call packetSeen.pushfront(*myMsg);
                    return msg;
                }   
                 //if it is a neighbor ping, send out a neighbor ping reply
                else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 1 && myMsg->protocol == 1) {
                    dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping Reply\n");
                    makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 0, 1, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, myMsg->src);
                    call packetSeen.pushfront(*myMsg);
                    return msg;
                }
                //if packs list is empty, flood
                else if(call packetSeen.isEmpty()) {
                    makePack(&sendPackage, myMsg->src, myMsg->dest, --myMsg->TTL, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    dbg(FLOODING_CHANNEL, "Packet Flooded\n");
                    call packetSeen.pushfront(*myMsg);
                    return msg;
                }
                //checks all packs in "seen before" list
                for(count = 0; count < call packetSeen.size(); count++) {
                    srcSeq = call packetSeen.get(count);
                    //if same packet was received before, drop packet
                    if(myMsg->src == (&srcSeq)->src && myMsg->seq == (&srcSeq)->seq) {
                        dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                        call packetSeen.pushfront(*myMsg);
                        return msg;
                    }
                }
                //if goes past previous check, must be new pack so flood
                makePack(&sendPackage, myMsg->src, myMsg->dest, --myMsg->TTL, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                dbg(FLOODING_CHANNEL, "Packet Flooded\n");
                call packetSeen.pushfront(*myMsg);
                return msg;                     
            }
            //if packet destination matches node, read message
            else{
                dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
                //if it is a ping
                if(myMsg->protocol == 0) {
                    if(call seqNumber.isEmpty()){
                        call seqNumber.pushfront(0);
                    }
                    //send a ping reply
                    dbg(GENERAL_CHANNEL, "PING EVENT: REPLY \n");
                    makePack(&sendPackage, TOS_NODE_ID, myMsg->src, 20, 1, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    call seqNumber.pushfront(call seqNumber.front() + 1);
                    call seqNumber.popback();
                }
                call packetSeen.pushfront(*myMsg);
                return msg;
            }
        }
        dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }

    //send a ping
    event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
        dbg(GENERAL_CHANNEL, "PING EVENT \n");
        if(call seqNumber.isEmpty()) {
            call seqNumber.pushfront(0);
        }
        makePack(&sendPackage, TOS_NODE_ID, destination, 20, 0, call seqNumber.front(), payload, PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        call seqNumber.pushfront(call seqNumber.front() + 1);
        call seqNumber.popback();
    }

    //periodic neighbor discovery pings
    event void periodicTimer.fired() { 
        while(!(call neighbors.isEmpty())) {
            call neighbors.popback();
        }
        if(call seqNumber.isEmpty()) {
            call seqNumber.pushfront(0);
        }
        dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping\n");
        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, 1, call seqNumber.front(), "", PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        call seqNumber.pushfront(call seqNumber.front() + 1);
        call seqNumber.popback();
    }

    //print list of neighbor nodes
    event void CommandHandler.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "Neighbors of Node %d:\n", TOS_NODE_ID);
        dbg(NEIGHBOR_CHANNEL, "--------------------\n");
        for(count = 0; count < call neighbors.size(); count++) {
            dbg(NEIGHBOR_CHANNEL, "       Node %d\n", call neighbors.get(count));
        }
        dbg(NEIGHBOR_CHANNEL, "--------------------\n");
    }

    event void CommandHandler.printRouteTable(){}

    event void CommandHandler.printLinkState(){}

    event void CommandHandler.printDistanceVector(){}

    event void CommandHandler.setTestServer(){}

    event void CommandHandler.setTestClient(){}

    event void CommandHandler.setAppServer(){}

    event void CommandHandler.setAppClient(){}

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }
}
