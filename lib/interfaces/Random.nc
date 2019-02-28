interface Random{
    command error_t Init.init();
    command error_t SeedInit.init(uint16_t s);
    async command uint32_t rand32();
    async command uint16_t rand16();
}