/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new ListC(uint16_t, 64) as seqNumber;
    components new ListC(pack, 64) as packetSeen;
    components new ListC(uint16_t, 64) as neighbors;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;
    Node.packetSeen -> packetSeen;
    Node.seqNumber -> seqNumber;
    Node.neighbors -> neighbors;
    Node.Receive -> GeneralReceive;
    
    components new TimerMilliC() as myTimerC;
    Node.periodicTimer -> myTimerC;

    components RandomC;
    Node.Random -> RandomC;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;
}
