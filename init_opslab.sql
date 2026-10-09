-- ============================================================
-- opslab 测试数据初始化脚本
-- 用途：为备份/恢复演练准备三表关联的测试数据
-- 表结构：customers / products / orders / order_items
-- 规模：60 客户 / 20 商品 / 50,000 订单 / 100,000 明细
-- 实测：执行耗时约 3.2 秒，磁盘占用约 30M
--
-- 执行方式：mysql < init_opslab.sql
-- ============================================================
SET NAMES utf8mb4;
USE opslab;

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;

-- ---------- 建表 ----------
CREATE TABLE customers (
  id      INT PRIMARY KEY AUTO_INCREMENT,
  name    VARCHAR(50)  NOT NULL,
  city    VARCHAR(30)  NOT NULL,
  phone   VARCHAR(20)  NOT NULL,
  created DATE         NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE products (
  id    INT PRIMARY KEY AUTO_INCREMENT,
  name  VARCHAR(60)    NOT NULL,
  price DECIMAL(10,2)  NOT NULL,
  stock INT            NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE orders (
  id          INT PRIMARY KEY AUTO_INCREMENT,
  customer_id INT           NOT NULL,
  order_no    VARCHAR(30)   NOT NULL,
  amount      DECIMAL(12,2) NOT NULL,
  status      VARCHAR(10)   NOT NULL,
  created_at  DATETIME      NOT NULL,
  KEY idx_customer (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE order_items (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  order_id   INT           NOT NULL,
  product_id INT           NOT NULL,
  qty        INT           NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,
  KEY idx_order (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------- 客户：60 条（中文姓名/城市，用于验证字符集）----------
INSERT INTO customers (name, city, phone, created)
SELECT
  CONCAT(
    ELT(1 + (seq.n % 10), '张','李','王','刘','陈','杨','赵','黄','周','吴'),
    ELT(1 + (seq.n % 8),  '伟','芳','娜','敏','静','强','磊','军')
  ),
  ELT(1 + (seq.n % 6), '北京','上海','广州','深圳','杭州','成都'),
  CONCAT('138', LPAD(seq.n, 8, '0')),
  DATE_ADD('2026-01-01', INTERVAL (seq.n % 180) DAY)
FROM (
  SELECT a.d + b.d * 10 AS n
  FROM (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
        UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
  CROSS JOIN (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
        UNION SELECT 5) b
) seq;

-- ---------- 商品：20 条 ----------
INSERT INTO products (name, price, stock)
SELECT
  CONCAT('商品-', seq.n, '号'),
  ROUND(9.9 + seq.n * 7.3, 2),
  100 + seq.n * 3
FROM (
  SELECT a.d + b.d * 10 AS n
  FROM (SELECT 1 d UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
        UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) a
  CROSS JOIN (SELECT 0 d UNION SELECT 1) b
) seq;

-- ---------- 订单：5 万条 ----------
-- 借助 information_schema 生成序号 0..49999
-- （MySQL 5.7 不支持递归 CTE，故用此方式造序列）
INSERT INTO orders (customer_id, order_no, amount, status, created_at)
SELECT
  1 + (seq.n % 60)                                        AS customer_id,
  CONCAT('ORD', LPAD(seq.n, 8, '0'))                      AS order_no,
  ROUND(50 + RAND() * 950, 2)                             AS amount,
  ELT(1 + (seq.n % 4), '待付款','已付款','已发货','已完成')  AS status,
  DATE_ADD('2026-01-01 00:00:00',
           INTERVAL (seq.n * 7) MINUTE)                   AS created_at
FROM (
  SELECT @rn := @rn + 1 AS n
  FROM information_schema.COLUMNS a
  CROSS JOIN information_schema.COLUMNS b
  CROSS JOIN (SELECT @rn := -1) init
  LIMIT 50000
) seq;

-- ---------- 订单明细：10 万条（每单 2 条）----------
-- unit_price 取自 products 表，保证与商品价格一致
INSERT INTO order_items (order_id, product_id, qty, unit_price)
SELECT
  o.id                                  AS order_id,
  p.id                                  AS product_id,
  (i.n % 5) + 1                         AS qty,
  p.price                               AS unit_price
FROM orders o
JOIN products p ON p.id = 1 + ((o.id * 3) % 20)
CROSS JOIN (SELECT 0 n UNION SELECT 1) i;

SELECT '初始化完成' AS 状态,
       (SELECT COUNT(*) FROM customers)   AS 客户数,
       (SELECT COUNT(*) FROM products)    AS 商品数,
       (SELECT COUNT(*) FROM orders)      AS 订单数,
       (SELECT COUNT(*) FROM order_items) AS 明细数;
