### TFG de Monitorización y Análisis de Arquitecturas Cloud basadas en Contenedores   
#### **Autor: Marcos Casado Ruiz**

## Despliegue básico mediante plantilla de despliegue CloudFormation y bastión (EC2)

**Paso 1**: Crear una VPC (VPC & More) con CIDR 10.0.0.0/16 en 1 AZ (zona de disponibilidad) con una subred pública con CIDR 10.0.0.0/24 en us-east-1a.  
**IMPORTANTE: Marcar la opción "Enable DNS hostnames" en la VPC.**

**Paso 2**: Crear una EC2 **en la misma VPC** creada en el paso 1 y con una IP pública asignada.

**Paso 3**: Instalar git y clonar el repositorio en el bastión Amazon Linux 2023 (EC2):
```bash
   sudo dnf install git -y
   git clone https://github.com/etsiinf-marcoscr/arch2sb_deployment.git
```

**Paso 4**: Enviar la clave de acceso SSH (desde su terminal local donde ha descargado la clave):
```bash
   scp -i arch2.pem arch2.pem ec2-user@<IP-PUBLICA-EC2>:~/arch2sb_deployment/
```

**Paso 5**: Configurar las credenciales AWS (también podría usarse ```aws login```):
```bash
   aws configure
```

**Paso 6**: Exportar la variable de entorno ```EMAIL``` que se le asociará al usuario 'frank' creado en el stack:
```bash
   export EMAIL="tu@email.com"
```

**Paso 7**: Dar permisos de ejecución al script de despliegue y ejecutarlo:
```bash
   cd arch2sb_deployment/
   chmod +x arch2sb-setup.sh && ./arch2sb-setup.sh
```

**Paso 8 (_opcional_)**: Para borrar los recursos desplegados por el script, ejecute el siguiente comando:
```bash
   chmod +x arch2sb-teardown.sh && ./arch2sb-teardown.sh
```
_Tenga en cuenta que necesitará eliminar todavía el bastión EC2, el certificado ACM autofirmado y la VPC manualmente desde la consola de AWS en sus respectivos servicios, ya que el script no los borra._
