drop table if exists Todo;
drop sequence if exists Todo_SEQ;
create sequence Todo_SEQ start 1 increment 1;
create table Todo (
       id int8 not null,
       completed boolean not null,
       ordering int4,
       title varchar(255),
       url varchar(255),
       primary key (id)
    );