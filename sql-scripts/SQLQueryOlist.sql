-- Create a new table with common state names
CREATE TABLE OlistStateNames (
    state_abbr CHAR(2) PRIMARY KEY, 
    state_fullname NVARCHAR(50)
);

INSERT INTO OlistStateNames (state_abbr, state_fullname)
VALUES
('AC', 'Acre'),
('AL', 'Alagoas'),
('AP', 'Amapá'),
('AM', 'Amazonas'),
('BA', 'Bahia'),
('CE', 'Ceará'),
('DF', 'Distrito Federal'),
('ES', 'Espírito Santo'),
('GO', 'Goiás'),
('MA', 'Maranhão'),
('MT', 'Mato Grosso'),
('MS', 'Mato Grosso do Sul'),
('MG', 'Minas Gerais'),
('PA', 'Pará'),
('PB', 'Paraíba'),
('PR', 'Paraná'),
('PE', 'Pernambuco'),
('PI', 'Piauí'),
('RJ', 'Rio de Janeiro'),
('RN', 'Rio Grande do Norte'),
('RS', 'Rio Grande do Sul'),
('RO', 'Rondônia'),
('RR', 'Roraima'),
('SC', 'Santa Catarina'),
('SP', 'São Paulo'),
('SE', 'Sergipe'),
('TO', 'Tocantins');

-- Update the Geolocation table with the correct state names
UPDATE g
SET g.geolocation_state = s.state_fullname
FROM dbo.OlistGeolocation AS g
INNER JOIN OlistStateNames AS s ON g.geolocation_state = s.state_abbr;

-- Create a temporary table without duplicate rows
SELECT 
	geolocation_zip_code_prefix,
	geolocation_lat,
	geolocation_lng,
	geolocation_city,
	geolocation_state
INTO #GeolocationCleaned
FROM (
	SELECT
		geolocation_zip_code_prefix,
		geolocation_lat,
		geolocation_lng,
		geolocation_city,
		geolocation_state,
		ROW_NUMBER() OVER(PARTITION BY geolocation_zip_code_prefix ORDER BY geolocation_city DESC) AS row_num
	FROM dbo.OlistGeolocation
	) AS Temp
WHERE row_num = 1

-- Create a temporary table for customers
SELECT
	o.order_id, 
	o.customer_id, 
	o.order_status,
	o.order_purchase_timestamp,
	o.order_approved_at,
	o.order_delivered_carrier_date,
	o.order_delivered_customer_date,
	o.order_estimated_delivery_date,
	gc.geolocation_state AS customer_state,
	c.customer_zip_code_prefix,
	orv.review_score,
	op.payment_installments,
	op.payment_sequential,
	op.payment_type,
	op.payment_value,
	gc.geolocation_lat AS customer_lat,
	gc.geolocation_lng AS customer_lng
INTO #CustomersInfo
FROM dbo.OlistOrders AS o
INNER JOIN OlistCustomers AS c ON o.customer_id = c.customer_id
LEFT JOIN OlistOrderReviews AS orv ON o.order_id = orv.order_id
INNER JOIN OlistOrderPayments AS op ON o.order_id = op.order_id
LEFT JOIN #GeolocationCleaned AS gc ON c.customer_zip_code_prefix = gc.geolocation_zip_code_prefix

-- Create a temporary table for sellers
SELECT 
	oi.order_id,
	oi.order_item_id,
	oi.product_id,
	oi.seller_id,
	oi.shipping_limit_date,
	oi.price,
	oi.freight_value,
	s.seller_zip_code_prefix,
	gc.geolocation_state AS seller_state,
	pcn.English AS product_category_name,
	gc.geolocation_lat AS seller_lat,
	gc.geolocation_lng AS seller_lng
INTO #SellersInfo
FROM dbo.OlistOrderItems AS oi
LEFT JOIN OlistSellers AS s ON oi.seller_id = s.seller_id
INNER JOIN OlistProducts AS opr ON oi.product_id = opr.product_id
LEFT JOIN #GeolocationCleaned AS gc ON s.seller_zip_code_prefix = gc.geolocation_zip_code_prefix
LEFT JOIN OlistProductCategoryNameTranslation AS pcn ON opr.product_category_name = pcn.Portuguese

-- Check the CUSTOMERS data
SELECT TOP 10 *
FROM #CustomersInfo

-- See what are the best payment types
SELECT 
    payment_type, 
    CAST(SUM(payment_value) AS INT) AS total_payment_value
FROM #CustomersInfo
GROUP BY payment_type
ORDER BY total_payment_value DESC;

-- Check if there are some data without a state value
SELECT DISTINCT(customer_zip_code_prefix)
FROM #CustomersInfo
WHERE customer_state IS NULL

-- Look for the states where there is the most customer spending, and see the number of orders and the average score.
SELECT 
    customer_state, 
	RANK() OVER(ORDER BY SUM(payment_value) DESC) AS rank_states_orders,
	CAST(SUM(payment_value) AS INT) AS value_per_state,
	COUNT(*) AS orders_per_state,
	AVG(CAST(review_score AS DECIMAL(10,2))) AS average_review_score
FROM #CustomersInfo
WHERE customer_state IS NOT NULL
GROUP BY customer_state
ORDER BY rank_states_orders;

-- Look for late shipments
SELECT 
    order_id,
    DATEDIFF(DAY, order_estimated_delivery_date, order_delivered_customer_date) AS delay_days
FROM #CustomersInfo
WHERE order_delivered_carrier_date > order_estimated_delivery_date
AND order_status = 'delivered'
ORDER BY delay_days DESC

-- Check how long it takes for an order to be approved
WITH ApprovalTime AS (
	SELECT 
		CASE 
			WHEN DATEDIFF(DAY, order_purchase_timestamp, order_approved_at) < 1 THEN 'Same Day'
			WHEN DATEDIFF(DAY, order_purchase_timestamp, order_approved_at) <= 3 THEN '1-3 Days'
			ELSE 'More than 3 Days'
		END AS approval_time_category
	FROM #CustomersInfo
)
SELECT approval_time_category, COUNT(*) AS total_orders
FROM ApprovalTime
GROUP BY approval_time_category
ORDER BY total_orders DESC

-- Now check the SELLERS data
SELECT COUNT(*)
FROM #SellersInfo

-- Check which states are the best at selling
SELECT 
    seller_state, 
    COUNT(*) AS total_orders,
	CAST(SUM(price + freight_value) AS INT) AS total_state_value,
	RANK() OVER(ORDER BY SUM(price + freight_value) DESC) AS rank_seller_state
FROM #SellersInfo
WHERE seller_state IS NOT NULL
GROUP BY seller_state
ORDER BY rank_seller_state;

-- Check which are the best-selling product categories.
SELECT 
    product_category_name, 
    COUNT(*) AS total_orders,
	CAST(SUM(price + freight_value) AS INT) AS total_category_value,
	CAST(AVG(price + freight_value) AS INT) AS avg_category_value,
	RANK() OVER(ORDER BY SUM(price + freight_value) DESC) AS rank_product_category
FROM #SellersInfo
WHERE  product_category_name IS NOT NULL
GROUP BY product_category_name
ORDER BY rank_product_category;

-- Top 3 product categories per state
WITH ProductPerState AS (
	SELECT 
		seller_state, 
		product_category_name, 
		COUNT(*) AS total_products,
		RANK() OVER(PARTITION BY seller_state ORDER BY COUNT(*) DESC) AS rank_state_product
	FROM #SellersInfo
	GROUP BY seller_state, product_category_name
)
SELECT 
	seller_state,
	product_category_name,
	total_products,
	rank_state_product
FROM ProductPerState
WHERE rank_state_product <= 3
AND seller_state IS NOT NULL
ORDER BY seller_state, rank_state_product
 
-- Look for late shipments
SELECT 
	DISTINCT(ci.order_id),
	si.seller_state,
	DATEDIFF(DAY, si.shipping_limit_date, ci.order_delivered_carrier_date) AS delay_days
FROM #CustomersInfo AS ci
INNER JOIN #SellersInfo AS si
	ON ci.order_id = si.order_id
WHERE ci.order_status = 'delivered'
AND ci.order_delivered_carrier_date > si.shipping_limit_date
ORDER BY delay_days DESC

-- VIEWS
-- CREATE A PERMANENT GEOLOCATIONCLEANED TABLE
SELECT 
	geolocation_zip_code_prefix,
	geolocation_lat,
	geolocation_lng,
	geolocation_city,
	geolocation_state
INTO PermanentGeolocationCleaned
FROM (
	SELECT
		geolocation_zip_code_prefix,
		geolocation_lat,
		geolocation_lng,
		geolocation_city,
		geolocation_state,
		ROW_NUMBER() OVER(PARTITION BY geolocation_zip_code_prefix ORDER BY geolocation_city DESC) AS row_num
	FROM dbo.OlistGeolocation
	) AS Temp
WHERE row_num = 1

-- CREATE A VIEW FOR CUESTOMERS DATA
CREATE VIEW vw_customers AS
SELECT
	o.order_id, 
	o.customer_id, 
	o.order_status,
	o.order_purchase_timestamp,
	o.order_approved_at,
	o.order_delivered_carrier_date,
	o.order_delivered_customer_date,
	o.order_estimated_delivery_date,
	gc.geolocation_state AS customer_state,
	c.customer_zip_code_prefix,
	orv.review_score,
	op.payment_installments,
	op.payment_sequential,
	op.payment_type,
	op.payment_value,
	gc.geolocation_lat AS customer_lat,
	gc.geolocation_lng AS customer_lng
FROM dbo.OlistOrders AS o
INNER JOIN OlistCustomers AS c ON o.customer_id = c.customer_id
LEFT JOIN OlistOrderReviews AS orv ON o.order_id = orv.order_id
INNER JOIN OlistOrderPayments AS op ON o.order_id = op.order_id
LEFT JOIN PermanentGeolocationCleaned AS gc ON c.customer_zip_code_prefix = gc.geolocation_zip_code_prefix

-- CREATE A VIEW FOR SELLERS DATA
CREATE VIEW vw_sellers AS
SELECT 
	oi.order_id,
	oi.order_item_id,
	oi.product_id,
	oi.seller_id,
	oi.shipping_limit_date,
	oi.price,
	oi.freight_value,
	s.seller_zip_code_prefix,
	gc.geolocation_state AS seller_state,
	pcn.English AS product_category_name,
	gc.geolocation_lat AS seller_lat,
	gc.geolocation_lng AS seller_lng
FROM dbo.OlistOrderItems AS oi
LEFT JOIN OlistSellers AS s ON oi.seller_id = s.seller_id
INNER JOIN OlistProducts AS opr ON oi.product_id = opr.product_id
LEFT JOIN PermanentGeolocationCleaned AS gc ON s.seller_zip_code_prefix = gc.geolocation_zip_code_prefix
LEFT JOIN OlistProductCategoryNameTranslation AS pcn ON opr.product_category_name = pcn.Portuguese