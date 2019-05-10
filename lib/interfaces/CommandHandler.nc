interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint8_t port);
   event void setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer);
   event void closeClient(uint16_t dest, uint8_t srcPort, uint8_t destPort);
   event void setAppServer(uint8_t port);
   event void setAppClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint8_t *username);
   event void broadcastMessage(uint8_t port, uint8_t *payload);
   event void whisperMessage(uint8_t port, uint8_t *username, uint8_t *payload);
   event void listUsers(uint8_t port);
}
