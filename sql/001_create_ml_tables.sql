create table if not exists ml_config_conta (
  id serial primary key,
  site_id varchar(10) not null default 'MLB',
  seller_id varchar(30) not null,
  client_id varchar(120),
  client_secret varchar(200),
  access_token text,
  refresh_token text,
  token_expires_at timestamp,
  ativo char(1) not null default 'S',
  criado_em timestamp not null default current_timestamp,
  atualizado_em timestamp not null default current_timestamp
);

create unique index if not exists ux_ml_config_conta_seller
  on ml_config_conta (seller_id);

create table if not exists ml_pedido (
  id serial primary key,
  order_id varchar(40) not null,
  pack_id varchar(40),
  shipment_id varchar(40),
  status varchar(40),
  status_detail varchar(80),
  buyer_id varchar(40),
  buyer_document varchar(30),
  buyer_name varchar(160),
  total_amount numeric(15,2) not null default 0,
  paid_amount numeric(15,2) not null default 0,
  raw_json text,
  numdoc integer,
  import_status varchar(30) not null default 'PENDENTE',
  import_error text,
  nfe_send_status varchar(30) not null default 'PENDENTE',
  nfe_send_error text,
  criado_em timestamp not null default current_timestamp,
  atualizado_em timestamp not null default current_timestamp
);

create unique index if not exists ux_ml_pedido_order
  on ml_pedido (order_id);

create index if not exists ix_ml_pedido_numdoc
  on ml_pedido (numdoc);

create table if not exists ml_pedido_item (
  id serial primary key,
  ml_pedido_id integer not null references ml_pedido(id) on delete cascade,
  order_id varchar(40) not null,
  item_id varchar(40),
  seller_sku varchar(80),
  title varchar(300),
  quantity numeric(15,4) not null default 0,
  unit_price numeric(15,4) not null default 0,
  cod_produto integer,
  raw_json text
);

create table if not exists ml_nfe_envio (
  id serial primary key,
  ml_pedido_id integer not null references ml_pedido(id) on delete cascade,
  numdoc integer not null,
  pack_id varchar(40),
  shipment_id varchar(40),
  chave_nfe varchar(60),
  protocolo_nfe varchar(80),
  xml text,
  status varchar(30) not null default 'PENDENTE',
  tentativas integer not null default 0,
  erro text,
  enviado_em timestamp,
  criado_em timestamp not null default current_timestamp,
  atualizado_em timestamp not null default current_timestamp
);

create unique index if not exists ux_ml_nfe_envio_numdoc
  on ml_nfe_envio (numdoc);
