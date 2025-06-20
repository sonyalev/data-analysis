library(tidyverse)
library(geosphere)
library(qqplotr)
library(GGally)
library(dplyr)
library(sf)
library(leaflet)
library(htmlwidgets)

# Завантаження даних

df_items <- read_csv("D:/Rproject/olist_order_items_dataset.csv")
df_reviews <- read_csv("D:/Rproject/olist_order_reviews_dataset.csv")
df_orders <- read_csv("D:/Rproject/olist_orders_dataset.csv")
df_products <- read_csv("D:/Rproject/olist_products_dataset.csv")
df_sellers <- read_csv("D:/Rproject/olist_sellers_dataset.csv")
df_customers <- read_csv("D:/Rproject/olist_customers_dataset.csv")
df_category <- read_csv("D:/Rproject/product_category_name_translation.csv")

# Об'єднання таблиць
df <- df_orders %>%
  inner_join(df_items, by = "order_id") %>%
  inner_join(df_reviews, by = "order_id", relationship = "many-to-many") %>%
  inner_join(df_products, by = "product_id") %>%
  inner_join(df_customers, by = "customer_id") %>%
  inner_join(df_sellers, by = "seller_id") %>%
  inner_join(df_category, by = "product_category_name")


#---------------------- Очищення -----------------------

# Перевірка скільки NA значень
df %>%
  summarize(across(everything(), ~ mean(is.na(.)))) %>%
  select(where(~ all(.) > 0)) %>%
  pivot_longer(cols = everything(), names_to = "Variable", values_to = "Missing_Pct")

# Видалення непотрібних колонок
df_clean <- df %>%
  select(-review_comment_title, -review_comment_message, -product_category_name, -order_item_id,-shipping_limit_date, -review_answer_timestamp, -customer_id) %>%
  rename(product_category_name = product_category_name_english)


# Видалення NA
df_clean <- df_clean %>% drop_na()

# Перекодування
df_clean <- df_clean %>%
  mutate(
    order_status = as.factor(order_status),
    customer_state = as.factor(customer_state),
    seller_state = as.factor(seller_state),
    product_category_name = as.factor(product_category_name),
    review_score = as.factor(review_score)
  )
df_clean <- df_clean %>%
  mutate(
    order_purchase_timestamp = as.POSIXct(order_purchase_timestamp, format = "%Y-%m-%d %H:%M:%S"),
    order_approved_at = as.POSIXct(order_approved_at, format = "%Y-%m-%d %H:%M:%S"),
    order_delivered_customer_date = as.POSIXct(order_delivered_customer_date, format = "%Y-%m-%d %H:%M:%S"),
    order_estimated_delivery_date = as.POSIXct(order_estimated_delivery_date, format = "%Y-%m-%d %H:%M:%S"),
    review_creation_date = as.Date(review_creation_date, format = "%Y-%m-%d")
  )


# Перевірка узгодженості freight_value для одного замовлення
df_clean <- df_clean %>%
  group_by(order_id) %>%
  mutate(freight_value_consistent = n_distinct(freight_value) == 1) %>%
  ungroup()

# Фільтрація тільки узгоджених значень freight_value
df_clean <- df_clean %>%
  filter(freight_value_consistent) %>%
  select(-freight_value_consistent)


# Видаляємо рядки з нульовою вагою, довжиною, шириною, висотою
df_clean <- df_clean %>%
  filter(product_weight_g > 0) %>%
  filter(product_length_cm > 0) %>%
  filter(product_height_cm > 0) %>%
  filter(product_width_cm > 0)

df_clean <- df_clean %>% filter(product_weight_g <= 30000)


#--------------------- Нові змінні ---------------------------------


# Час доставки у днях
df_clean <- df_clean %>%
  mutate(
    actual_delivery_time = as.numeric(difftime(order_delivered_customer_date, order_purchase_timestamp, units = "days")),
    estimated_delivery_time = as.numeric(difftime(order_estimated_delivery_date, order_purchase_timestamp, units = "days"))
  )


# Функція для розрахунку відстані між продавцем та покупцем
state_capitals <- list(
  "AC" = c(-9.97499, -67.8243),   # Ріо-Бранко
  "AL" = c(-9.64985, -35.7089),   # Масейо
  "AM" = c(-3.10194, -60.025),    # Манаус
  "AP" = c(0.03889, -51.0664),    # Макапа
  "BA" = c(-12.9714, -38.5014),   # Салвадор
  "CE" = c(-3.71722, -38.5434),   # Форталеза
  "DF" = c(-15.7801, -47.9292),   # Бразиліа
  "ES" = c(-20.3155, -40.3128),   # Віторія
  "GO" = c(-16.6864, -49.2643),   # Гоянія
  "MA" = c(-2.53073, -44.3068),   # Сан-Луїс
  "MG" = c(-19.9167, -43.9345),   # Белу-Оризонті
  "MS" = c(-20.4428, -54.6464),   # Кампу-Гранді
  "MT" = c(-15.601, -56.0974),    # Куяба
  "PA" = c(-1.45502, -48.5024),   # Белен
  "PB" = c(-7.11509, -34.8641),   # Жуан-Песоа
  "PE" = c(-8.04756, -34.877),    # Ресіфі
  "PI" = c(-5.08921, -42.8016),   # Терезіна
  "PR" = c(-25.4284, -49.2733),   # Куритиба
  "RJ" = c(-22.9068, -43.1729),   # Ріо-де-Жанейро
  "RN" = c(-5.79448, -35.211),    # Натал
  "RO" = c(-8.76116, -63.9039),   # Порту-Велью
  "RR" = c(2.81972, -60.6733),    # Боа-Віста
  "RS" = c(-30.0346, -51.2177),   # Порту-Алегрі
  "SC" = c(-27.5954, -48.548),    # Флоріанополіс
  "SE" = c(-10.9472, -37.0731),   # Аракажу
  "SP" = c(-23.5505, -46.6333),   # Сан-Паулу
  "TO" = c(-10.184, -48.3336)     # Палмас
)

# Функція для визначення відстані між продавцем та покупцем
calculate_distance <- function(seller_state, customer_state) {
  seller_state <- as.character(seller_state)   # Конвертація у character
  customer_state <- as.character(customer_state)

  seller_coords <- state_capitals[[seller_state]]
  customer_coords <- state_capitals[[customer_state]]

  if (!is.null(seller_coords) & !is.null(customer_coords)) {
    return(distVincentySphere(seller_coords, customer_coords) / 1000)  # Відстань у км
  } else {
    return(NA)  # Якщо немає даних
  }
}

# Відстань між продавцем та покупцем
df_clean <- df_clean %>%
  rowwise() %>%
  mutate(distance_km = calculate_distance(as.character(seller_state), as.character(customer_state))) %>%
  ungroup()



#---------------------- Розподіли та викиди -----------------------


# Ціна
ggplot(df_clean, aes(sample = price)) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "(Ціна, R$)") +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(sample = log1p(price))) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "ln(Ціна, R$)") +
  theme(text = element_text(size = 15))


# Вага
ggplot(df_clean, aes(sample = product_weight_g)) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "(Вага, г)") +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(sample = log(product_weight_g))) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "ln(Вага, г)") +
  theme(text = element_text(size = 15))


# Відстань між продавцем та покупцем
ggplot(df_clean, aes(x = distance_km)) +
  geom_histogram(bins=100) +
  labs(y = "Кількість", x = "(Відстань, км)") +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(sample = distance_km)) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "(Відстань, км)") +
  theme(text = element_text(size = 15))


# Вартість доставки
ggplot(df_clean, aes(sample = freight_value)) +
  stat_qq_point() + stat_qq_line() + stat_qq_band() +
  labs(x = "Квантилі нормального розподілу", y = "(Вартість доставки, R$)") +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = log1p(freight_value))) +
  geom_histogram(bins=200) +
  labs(y = "Кількість", x = "ln(Вартість доставки, R$)")  +
  theme(text = element_text(size = 15))

# Створюємо стовпчик log_freight_value
df_clean <- df_clean %>%
  mutate(
    log_freight_value = log1p(freight_value)
  )

# Розподіл ln(ціни) для різних інтервалів ln(freight_value)
ggplot(df_clean,
       aes(x = log(price), y = after_stat(density),
           color = cut(log_freight_value, breaks = c(0, 2.29, 3.559, max(log_freight_value)),
                       include.lowest = TRUE, right = FALSE))) +
  geom_freqpoly(bins = 50) +
  labs(x = "ln(Ціна, R$)", y = "Щільність", color = "ln(Вартість доставки, R$)") +
  theme(text = element_text(size = 15))

# Розподіл ln(ваги) для різних інтервалів ln(freight_value)
ggplot(df_clean,
       aes(x = log(product_weight_g), y = after_stat(density),
           color = cut(log_freight_value, breaks = c(0, 2.29, 3.559, max(log_freight_value)),
                       include.lowest = TRUE, right = FALSE))) +
  geom_freqpoly(bins = 50) +
  labs(x = "ln(Вага, г)", y = "Щільність", color = "ln(Вартість доставки, R$)") +
  theme(text = element_text(size = 15))

# Розподіл ln(відстані) для різних інтервалів ln(freight_value)
ggplot(df_clean,
       aes(x = log1p(distance_km), y = after_stat(density),
           color = cut(log_freight_value, breaks = c(0, 2.29, 3.559, max(log_freight_value)),
                       include.lowest = TRUE, right = FALSE))) +
  geom_freqpoly(bins = 50) +
  labs(x = "ln(Відстань, км)", y = "Щільність", color = "ln(Вартість доставки, R$)") +
  theme(text = element_text(size = 15))



# Довжина, ширина, висота
ggplot(df_clean, aes(x = product_length_cm)) +
  geom_histogram(bins=80) +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = product_height_cm)) +
  geom_histogram(bins=80) +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = product_width_cm)) +
  geom_histogram(bins=80) +
  theme(text = element_text(size = 15))


# Оцінка, product_name_lenght,product_description_lenght, product_photos_qty
ggplot(df_clean, aes(x = review_score)) +
  geom_bar() +
  labs(x = "review_score", y = "Кількість") +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = product_name_lenght)) +
  geom_histogram(bins=50) +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = product_description_lenght)) +
  geom_histogram(bins=50) +
  theme(text = element_text(size = 15))
ggplot(df_clean, aes(x = product_photos_qty)) +
  geom_bar() +
  labs(x = "product_photos_qty", y = "Кількість") +
  theme(text = element_text(size = 15))


