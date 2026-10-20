# WorbyMLIntegrador

Worker Delphi para integrar pedidos do Mercado Livre com o ORBI/Worby.

## Objetivo

Fluxo previsto:

1. Renovar token OAuth do Mercado Livre.
2. Consultar pedidos pagos do vendedor.
3. Gravar o pedido bruto em tabelas de staging `ml_*`.
4. Importar cliente e pedido para o ORBI.
5. Marcar `vendas1.solicitar_emissor = 'EMISSAO'`.
6. Aguardar o `EmissorFila` autorizar a NF-e.
7. Enviar o XML da NF-e para o Mercado Livre.

O projeto nao substitui o `EmissorFila`. Ele prepara o pedido e acompanha o envio da nota ao Mercado Livre.

## Pasta

- `src`: codigo Delphi do worker.
- `sql`: tabelas de controle da integracao.
- `docs`: observacoes de arquitetura.
- `config.example.ini`: modelo de configuracao.

## Primeiro uso

1. Execute o SQL de `sql\001_create_ml_tables.sql` no banco ORBI.
2. Copie `config.example.ini` para `config.ini`.
3. Preencha credenciais PostgreSQL e Mercado Livre.
4. Compile `src\WorbyMLIntegrador.dpr`.
5. Rode em modo monitorado no servidor.

## Estado atual

Esta primeira versao cria a estrutura do integrador e deixa pontos isolados para completar o mapeamento fiscal do cliente:

- Produto Mercado Livre para `produto.cod_produto`.
- Dados do comprador para `cliente`.
- Campos comerciais obrigatorios em `vendas1`.
- Regras de frete, desconto e forma de pagamento.

Depois desses mapeamentos, o worker ja fica no desenho correto para operar junto com o `EmissorFila`.
