# Arquitetura da integracao Mercado Livre

## Decisao principal

O `WorbyMLIntegrador` deve ser um processo separado do `EmissorFila`.

Motivo: o `EmissorFila` ja executa a etapa fiscal critica com ACBr, SEFAZ, certificado e gravacao de XML/protocolo. A API do Mercado Livre adiciona OAuth, consulta de pedidos, webhook, retry externo e envio de documento. Separar os processos reduz risco e facilita suporte.

## Fronteira entre os processos

Entrada do emissor:

- `vendas1.solicitar_emissor = 'EMISSAO'`
- `vendas1.status_emissor` diferente de `EM ANDAMENTO` e `CONCLUIDO`

Saida do emissor:

- `vendas1.status_emissor = 'CONCLUIDO'`
- `vendas1.chave_nfe`
- `vendas1.protocolo_nfe`
- `vendas1.xml`

O integrador acompanha essa saida e envia o XML ao Mercado Livre.

## Tabelas novas

- `ml_config_conta`: tokens e dados da conta Mercado Livre.
- `ml_pedido`: vinculo entre pedido/pack Mercado Livre e `vendas1.numdoc`.
- `ml_pedido_item`: snapshot dos itens do pedido.
- `ml_nfe_envio`: fila de envio do XML da NF-e ao Mercado Livre.

## Pendencias de regra de negocio

- Confirmar endpoint atual para envio de NF-e conforme tipo logistico.
- Confirmar se o cliente quer emitir uma NF-e por pack ou por order.
- Definir mapeamento SKU Mercado Livre para `produto.cod_produto`.
- Definir cliente consumidor final quando o Mercado Livre omitir documento/endereco.
- Definir CFOP, prazo, representante e empresa por conta/anuncio.
