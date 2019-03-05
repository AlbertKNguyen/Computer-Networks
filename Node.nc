/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

//Implremented by Albert Nguyen

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
    uses interface List<uint16_t> as neighborsList;
    uses interface Hashmap<uint16_t> as seqNumbers;
    uses interface Hashmap<uint8_t*> as linkState;
    uses interface Hashmap<uint16_t> as nodeDistance;
    uses interface Hashmap<uint16_t> as routeTable;
    uses interface SimpleSend as Sender;

    uses interface CommandHandler;
}

implementation {
    pack sendPackage, srcSeq;
    uint16_t i, j, minNode, min;
    uint16_t nodeNeighbors[64][64];
    uint32_t* destNode; 
    uint32_t* linkStateNodes;
    uint16_t* linkStateNeighbors;
    uint16_t nodeGraph[64][64];
    uint8_t isConsidered[64], nextHopNeighbor;

    // Prototypes
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
    void updateRouteTable();

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
                //if source's sequence number is in map, compare sequence number in map to packet's
                if(call seqNumbers.contains(myMsg->src)) {
                    //if same/old packet was received, drop packet
                    if(myMsg->seq < call seqNumbers.get(myMsg->src)) {
                        dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                        return msg;
                    }
                }
                //if packet is a neighbor ping reply, then source is neighbor
                if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 0 && myMsg->protocol == 1) {
                    dbg(FLOODING_CHANNEL, "Found Node %d as Neighbor\n", myMsg->src);
                    call neighborsList.pushfront(myMsg->src);
                    //update route table and broadcast link-state packet
                    updateRouteTable();
                    for(i = 0; i < call neighborsList.size(); i++) {
                        nodeNeighbors[TOS_NODE_ID][i] = call neighborsList.get(i);
                    }
                    nodeNeighbors[TOS_NODE_ID][call neighborsList.size()] = 0;
                    makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 20, 2, call seqNumbers.get(TOS_NODE_ID), nodeNeighbors[TOS_NODE_ID], PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                }
                //drop packet if the source of the packet matches node or TTL is 0
                else if(TOS_NODE_ID == myMsg->src || myMsg->TTL == 0) {
                    dbg(GENERAL_CHANNEL, "Packet Dropped\n");
                }   
                //if it is a neighbor ping, send out a neighbor ping reply
                else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->TTL == 1 && myMsg->protocol == 0) {
                    if(!call seqNumbers.contains(TOS_NODE_ID)) {
                        call seqNumbers.insert(TOS_NODE_ID, 0);
                    }                    
                    dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping Reply\n");
                    makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 0, 1, call seqNumbers.get(TOS_NODE_ID), myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, myMsg->src);
                    call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
                }
                //if it is a broadcasted link-state packet, store the information and flood
                else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->protocol == 2) {
                    //insert link-state pack into link-state map
                    i= 0;
                    while(*(myMsg->payload + i) != 0) {
                        nodeNeighbors[myMsg->src][i] = *(myMsg->payload + i);
                        i++;
                    }
                    nodeNeighbors[myMsg->src][i] = 0;
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
                    dbg(FLOODING_CHANNEL, "Packet Routed to Node %d\n", call routeTable.get(myMsg->dest));                        
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
                dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
                //if it is a new ping and not a ping reply
                if(myMsg->protocol == 0) {
                    if(!call seqNumbers.contains(TOS_NODE_ID)) {
                        call seqNumbers.insert(TOS_NODE_ID, 0);
                    }
                    //send a ping reply
                    dbg(GENERAL_CHANNEL, "PING EVENT: REPLY \n");
                    makePack(&sendPackage, TOS_NODE_ID, myMsg->src, 20, 1, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
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
        makePack(&sendPackage, TOS_NODE_ID, destination, 20, 0, call seqNumbers.get(TOS_NODE_ID), payload, PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        call seqNumbers.insert(TOS_NODE_ID, call seqNumbers.get(TOS_NODE_ID) + 1);
    }

    //periodic neighbor discovery pings
    event void periodicTimer.fired() { 
        while(!(call neighborsList.isEmpty())) {
            call neighborsList.popback();
        }
        if(!call seqNumbers.contains(TOS_NODE_ID)) {
             call seqNumbers.insert(TOS_NODE_ID, 0);
        }
        dbg(NEIGHBOR_CHANNEL, "Neighbor Discovery Ping\n");
        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, 0, call seqNumbers.get(TOS_NODE_ID), "", PACKET_MAX_PAYLOAD_SIZE);
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

    void updateRouteTable() {
        //insert its own link-state/neighbors into link-state map
        for(i = 0; i < call neighborsList.size(); i++) {
            nodeNeighbors[TOS_NODE_ID][i] = call neighborsList.get(i);
        }
        nodeNeighbors[TOS_NODE_ID][call neighborsList.size()] = 0;
        call linkState.insert(TOS_NODE_ID, nodeNeighbors[TOS_NODE_ID]);
        //linkStateNodes are the nodes that sent link-state packets
        linkStateNodes = call linkState.getKeys();
        //go through each node to initialize node distance 
        for(i = 0; i < call linkState.size(); i++) {
            call nodeDistance.insert(linkStateNodes[i], 999);
            isConsidered[linkStateNodes[i]] = 0;
            linkStateNeighbors = call linkState.get(linkStateNodes[i]);
            j = 0;
            //go through each neighbor of node to build graph
            while(linkStateNeighbors[j] != 0) {
                nodeGraph[linkStateNodes[i]][linkStateNeighbors[j]] = 1;
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
            isConsidered[minNode] = 1;
            //set variable to neighbors of considered node
            linkStateNeighbors = call linkState.get(minNode);
            //go through each neighbor of node and calculate distance values
            while(linkStateNeighbors[j] != 0) {
                if(!isConsidered[linkStateNeighbors[j]] && nodeGraph[minNode][linkStateNeighbors[j]] && call nodeDistance.get(minNode) != 999 
                && call nodeDistance.get(minNode) + nodeGraph[minNode][linkStateNeighbors[j]] < call nodeDistance.get(linkStateNeighbors[j])) {
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
                //if the next hop of destination is not a neighbor adjust it 1 node at a time until the next hop is a neighbor
                while(!nextHopNeighbor) {
                    for(j = 0; j < call neighborsList.size(); j++) {
                        if(call routeTable.get(destNode[i]) == call neighborsList.get(j)) {
                            nextHopNeighbor = 1;
                        }
                    }
                    if(!nextHopNeighbor) {
                        call routeTable.insert(destNode[i], call routeTable.get(destNode[i]));
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
