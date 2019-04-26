/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

//Implemented by Albert Nguyen

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new ListC(uint16_t, 64) as neighborsList;
    components new HashmapC(uint16_t, 64) as seqNumbers;
    components new HashmapC(uint8_t*, 64) as linkState;
    components new HashmapC(uint16_t, 64) as nodeDistance;
    components new HashmapC(uint16_t, 64) as routeTable;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;
    Node.seqNumbers -> seqNumbers;
    Node.neighborsList -> neighborsList;
    Node.linkState -> linkState;
    Node.nodeDistance -> nodeDistance;
    Node.routeTable -> routeTable;
    Node.Receive -> GeneralReceive;
    
    components new TimerMilliC() as periodicNeighbors;
    Node.periodicNeighbors -> periodicNeighbors;
   
    components new TimerMilliC() as periodicLinkState;
    Node.periodicLinkState -> periodicLinkState;

    components new TimerMilliC() as serverTimer;
    Node.serverTimer -> serverTimer;
   
    components new TimerMilliC() as clientTimer;
    Node.clientTimer -> clientTimer;

    components RandomC;
    Node.Random -> RandomC;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;
}
